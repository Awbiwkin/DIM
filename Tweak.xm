
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <stdio.h>
#import <errno.h>

static NSString * const DIMDomain = @"com.dim.manager";

// ============================================================
// ORIGINAL SYSTEM VERSION
// ============================================================

static NSString *DIMOriginalSystemVersion = nil;

// ============================================================
// FISHHOOK
// ============================================================

struct DIMRebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct DIMRebindingsEntry {
    struct DIMRebinding *rebindings;
    size_t count;
    struct DIMRebindingsEntry *next;
};

static struct DIMRebindingsEntry *DIMRebindingsHead = NULL;

static int (*DIMOriginalSysctlByName)(
    const char *, void *, size_t *, void *, size_t
) = NULL;

static int (*DIMOriginalSysctl)(
    int *, u_int, void *, size_t *, void *, size_t
) = NULL;

static int (*DIMOriginalSysctlNameToMIB)(
    const char *, int *, size_t *
) = NULL;

static int (*DIMOriginalUname)(
    struct utsname *
) = NULL;

static void DIMPerformRebinding(
    struct mach_header_64 *header,
    intptr_t slide,
    struct segment_command_64 *linkedit,
    struct symtab_command *symtab,
    struct dysymtab_command *dysymtab
) {
    if (!header || !linkedit || !symtab || !dysymtab) {
        return;
    }

    uintptr_t linkeditBase =
        (uintptr_t)slide +
        (uintptr_t)linkedit->vmaddr -
        (uintptr_t)linkedit->fileoff;

    struct nlist_64 *symbols =
        (struct nlist_64 *)(linkeditBase + symtab->symoff);

    char *strings =
        (char *)(linkeditBase + symtab->stroff);

    uint32_t *indirect =
        (uint32_t *)(linkeditBase + dysymtab->indirectsymoff);

    struct load_command *command =
        (struct load_command *)(
            (uintptr_t)header +
            sizeof(struct mach_header_64)
        );

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment =
                (struct segment_command_64 *)command;

            struct section_64 *sections =
                (struct section_64 *)(
                    (uintptr_t)segment +
                    sizeof(struct segment_command_64)
                );

            for (uint32_t j = 0; j < segment->nsects; j++) {
                uint32_t type =
                    sections[j].flags & SECTION_TYPE;

                if (type != S_LAZY_SYMBOL_POINTERS &&
                    type != S_NON_LAZY_SYMBOL_POINTERS) {
                    continue;
                }

                uintptr_t *bindings =
                    (uintptr_t *)(slide + sections[j].addr);

                uint32_t count =
                    (uint32_t)(
                        sections[j].size / sizeof(uintptr_t)
                    );

                for (uint32_t k = 0; k < count; k++) {
                    uint32_t index =
                        indirect[sections[j].reserved1 + k];

                    if (index == INDIRECT_SYMBOL_ABS ||
                        index == INDIRECT_SYMBOL_LOCAL ||
                        index == (
                            INDIRECT_SYMBOL_LOCAL |
                            INDIRECT_SYMBOL_ABS
                        )) {
                        continue;
                    }

                    const char *symbolName =
                        strings + symbols[index].n_un.n_strx;

                    if (!symbolName || symbolName[0] != '_') {
                        continue;
                    }

                    for (
                        struct DIMRebindingsEntry *entry =
                            DIMRebindingsHead;
                        entry;
                        entry = entry->next
                    ) {
                        for (size_t r = 0; r < entry->count; r++) {
                            struct DIMRebinding *binding =
                                &entry->rebindings[r];

                            if (strcmp(
                                symbolName + 1,
                                binding->name
                            ) != 0) {
                                continue;
                            }

                            if (binding->replaced &&
                                !*binding->replaced) {
                                *binding->replaced =
                                    (void *)bindings[k];
                            }

                            vm_address_t address =
                                (vm_address_t)&bindings[k];

                            vm_address_t page =
                                address &
                                ~((vm_address_t)vm_page_size - 1);

                            vm_protect(
                                mach_task_self(),
                                page,
                                vm_page_size,
                                false,
                                VM_PROT_READ |
                                VM_PROT_WRITE |
                                VM_PROT_COPY
                            );

                            bindings[k] =
                                (uintptr_t)binding->replacement;
                        }
                    }
                }
            }
        }

        command = (struct load_command *)(
            (uintptr_t)command + command->cmdsize
        );
    }
}

static void DIMRebindImage(
    const struct mach_header *header,
    intptr_t slide
) {
    if (!header || header->magic != MH_MAGIC_64) {
        return;
    }

    struct mach_header_64 *header64 =
        (struct mach_header_64 *)header;

    struct segment_command_64 *linkedit = NULL;
    struct symtab_command *symtab = NULL;
    struct dysymtab_command *dysymtab = NULL;

    struct load_command *command =
        (struct load_command *)(
            (uintptr_t)header64 +
            sizeof(struct mach_header_64)
        );

    for (uint32_t i = 0; i < header64->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment =
                (struct segment_command_64 *)command;

            if (strcmp(
                segment->segname,
                SEG_LINKEDIT
            ) == 0) {
                linkedit = segment;
            }
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab = (struct dysymtab_command *)command;
        }

        command = (struct load_command *)(
            (uintptr_t)command + command->cmdsize
        );
    }

    DIMPerformRebinding(
        header64,
        slide,
        linkedit,
        symtab,
        dysymtab
    );
}

static void DIMAddImage(
    const struct mach_header *header,
    intptr_t slide
) {
    DIMRebindImage(header, slide);
}

static int DIMRebindSymbols(
    struct DIMRebinding rebindings[],
    size_t count
) {
    struct DIMRebindingsEntry *entry =
        (struct DIMRebindingsEntry *)malloc(
            sizeof(struct DIMRebindingsEntry)
        );

    if (!entry) {
        return -1;
    }

    entry->rebindings =
        (struct DIMRebinding *)malloc(
            sizeof(struct DIMRebinding) * count
        );

    if (!entry->rebindings) {
        free(entry);
        return -1;
    }

    memcpy(
        entry->rebindings,
        rebindings,
        sizeof(struct DIMRebinding) * count
    );

    entry->count = count;
    entry->next = DIMRebindingsHead;
    DIMRebindingsHead = entry;

    _dyld_register_func_for_add_image(DIMAddImage);

    return 0;
}

// ============================================================
// CONFIGURATION
// ============================================================

static NSDictionary *DIMActiveConfiguration(void) {
    NSUserDefaults *prefs =
        [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];

    if (!prefs ||
        ![prefs boolForKey:@"Enabled"] ||
        ![prefs boolForKey:@"DeviceEnabled"]) {
        return nil;
    }

    BOOL global =
        [prefs boolForKey:@"GlobalProfileEnabled"];

    BOOL onlyIn =
        [prefs boolForKey:@"OnlyInEnabled"];

    if (!global && !onlyIn) {
        return nil;
    }

    NSString *bundleID =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    if (onlyIn && !global) {
        NSArray *apps =
            [prefs arrayForKey:@"SelectedApps"];

        if (![apps isKindOfClass:NSArray.class] ||
            ![apps containsObject:bundleID]) {
            return nil;
        }
    }

    NSString *identifier =
        [prefs stringForKey:@"SelectedModel"] ?: @"";

    NSString *version =
        [prefs stringForKey:@"SelectedVersion"] ?: @"";

    NSString *build =
        [prefs stringForKey:@"SelectedBuild"] ?: @"";

    NSString *family =
        [prefs stringForKey:@"DeviceFamily"] ?: @"";

    if (!identifier.length &&
        !version.length &&
        !build.length) {
        return nil;
    }

    NSArray *devices =
        [prefs arrayForKey:@"DIMCatalogDevices"];

    NSDictionary *device = nil;

    if ([devices isKindOfClass:NSArray.class]) {
        for (id candidate in devices) {
            if (![candidate isKindOfClass:NSDictionary.class]) {
                continue;
            }

            if ([candidate[@"identifier"]
                 isEqualToString:identifier]) {
                device = candidate;
                break;
            }
        }
    }

    id nameValue = device[@"name"];
    NSString *marketingName = nil;

    if ([nameValue isKindOfClass:NSString.class]) {
        marketingName = nameValue;
    }

    if (!marketingName.length) {
        marketingName = identifier;
    }

    id boardValue = device[@"boardconfig"];
    NSString *board = nil;

    if ([boardValue isKindOfClass:NSString.class]) {
        board = boardValue;
    } else if ([boardValue isKindOfClass:NSArray.class]) {
        NSArray *boardArray = (NSArray *)boardValue;

        if (boardArray.count > 0 &&
            [boardArray[0] isKindOfClass:NSString.class]) {
            board = boardArray[0];
        }
    }

    return @{
        @"identifier": identifier,
        @"name": marketingName ?: @"",
        @"board": board ?: @"",
        @"version": version,
        @"build": build,
        @"family": family
    };
}

static NSString *DIMValue(NSString *key) {
    NSDictionary *config = DIMActiveConfiguration();

    if (!config) {
        return nil;
    }

    id value = config[key];

    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }

    return [value length] ? value : nil;
}

// ============================================================
// ORIGINAL DARWIN RELEASE
// ============================================================

static NSString *DIMOriginalDarwinRelease(void) {
    if (!DIMOriginalSysctlByName) {
        return nil;
    }

    size_t size = 0;

    if (DIMOriginalSysctlByName(
        "kern.osrelease",
        NULL,
        &size,
        NULL,
        0
    ) != 0 || size == 0) {
        return nil;
    }

    char *buffer = (char *)calloc(1, size + 1);

    if (!buffer) {
        return nil;
    }

    NSString *result = nil;

    if (DIMOriginalSysctlByName(
        "kern.osrelease",
        buffer,
        &size,
        NULL,
        0
    ) == 0) {
        result = [NSString stringWithUTF8String:buffer];
    }

    free(buffer);

    return result;
}

// ============================================================
// DARWIN RELEASE MAPPING
// ============================================================

static NSString *DIMDarwinRelease(void) {
    NSString *version = DIMValue(@"version");

    if (!version.length) {
        return nil;
    }

    NSArray *parts =
        [version componentsSeparatedByString:@"."];

    NSInteger major =
        parts.count > 0 ? [parts[0] integerValue] : 0;

    if (major <= 0) {
        return DIMOriginalDarwinRelease();
    }

    // Major-version mapping.
    // Minor Darwin versions are not inferred from iOS minor versions.

    NSDictionary *mapping = @{
        @"9":  @"15.5.0",
        @"10": @"16.5.0",
        @"11": @"17.6.0",
        @"12": @"18.7.0",
        @"13": @"19.6.0",
        @"14": @"20.6.0",
        @"15": @"21.6.0",
        @"16": @"22.6.0",
        @"17": @"23.6.0",
        @"18": @"24.5.0",
        @"26": @"25.0.0"
    };

    NSString *mapped =
        mapping[[NSString stringWithFormat:@"%ld", (long)major]];

    if (mapped.length) {
        return mapped;
    }

    return DIMOriginalDarwinRelease();
}

// ============================================================
// KERNEL VERSION
// ============================================================

static NSString *DIMOriginalKernelVersion(void) {
    if (!DIMOriginalSysctlByName) {
        return nil;
    }

    size_t size = 0;

    if (DIMOriginalSysctlByName(
        "kern.version",
        NULL,
        &size,
        NULL,
        0
    ) != 0 || size == 0) {
        return nil;
    }

    char *buffer = (char *)calloc(1, size + 1);

    if (!buffer) {
        return nil;
    }

    NSString *result = nil;

    if (DIMOriginalSysctlByName(
        "kern.version",
        buffer,
        &size,
        NULL,
        0
    ) == 0) {
        result = [NSString stringWithUTF8String:buffer];
    }

    free(buffer);

    return result;
}

static NSString *DIMFakeKernelVersion(void) {
    NSString *original = DIMOriginalKernelVersion();
    NSString *release = DIMDarwinRelease();

    if (!original.length || !release.length) {
        return original;
    }

    NSRange prefix =
        [original rangeOfString:@"Darwin Kernel Version "];

    if (prefix.location == NSNotFound) {
        return original;
    }

    NSUInteger start = NSMaxRange(prefix);

    NSRange colon =
        [original rangeOfString:@":"
                        options:0
                          range:NSMakeRange(
                              start,
                              original.length - start
                          )];

    if (colon.location == NSNotFound) {
        return original;
    }

    return [NSString stringWithFormat:@"%@%@%@",
        [original substringToIndex:start],
        release,
        [original substringFromIndex:colon.location]];
}

// ============================================================
// BUFFER HELPERS
// ============================================================

static int DIMWriteString(
    NSString *value,
    void *oldp,
    size_t *oldlenp
) {
    if (!value.length) {
        return -1;
    }

    if (!oldlenp) {
        errno = EFAULT;
        return -1;
    }

    const char *string = value.UTF8String;

    if (!string) {
        errno = EINVAL;
        return -1;
    }

    size_t required = strlen(string) + 1;

    if (!oldp) {
        *oldlenp = required;
        return 0;
    }

    size_t available = *oldlenp;

    if (available < required) {
        *oldlenp = required;
        errno = ENOMEM;
        return -1;
    }

    memcpy(oldp, string, required);
    *oldlenp = required;

    return 0;
}

// ============================================================
// SYSCTLBYNAME
// ============================================================

static int DIMHookSysctlByName(
    const char *name,
    void *oldp,
    size_t *oldlenp,
    void *newp,
    size_t newlen
) {
    if (name && !newp) {
        NSString *replacement = nil;

        if (strcmp(name, "hw.machine") == 0) {
            replacement = DIMValue(@"identifier");
        } else if (strcmp(name, "hw.model") == 0) {
            replacement = DIMValue(@"board");
        } else if (strcmp(name, "kern.osversion") == 0) {
            replacement = DIMValue(@"build");
        } else if (strcmp(name, "kern.osrelease") == 0) {
            replacement = DIMDarwinRelease();
        } else if (strcmp(name, "kern.version") == 0) {
            replacement = DIMFakeKernelVersion();
        }

        if (replacement.length) {
            return DIMWriteString(
                replacement,
                oldp,
                oldlenp
            );
        }
    }

    if (DIMOriginalSysctlByName) {
        return DIMOriginalSysctlByName(
            name,
            oldp,
            oldlenp,
            newp,
            newlen
        );
    }

    errno = ENOSYS;
    return -1;
}

// ============================================================
// SYSCTL MIB
// ============================================================

static int DIMHookSysctl(
    int *name,
    u_int namelen,
    void *oldp,
    size_t *oldlenp,
    void *newp,
    size_t newlen
) {
    if (name && namelen == 2 && !newp) {
        NSString *replacement = nil;

        if (name[0] == CTL_HW &&
            name[1] == HW_MACHINE) {
            replacement = DIMValue(@"identifier");
        }

#ifdef HW_MODEL
        else if (name[0] == CTL_HW &&
                 name[1] == HW_MODEL) {
            replacement = DIMValue(@"board");
        }
#endif

#ifdef KERN_OSVERSION
        else if (name[0] == CTL_KERN &&
                 name[1] == KERN_OSVERSION) {
            replacement = DIMValue(@"build");
        }
#endif

#ifdef KERN_OSRELEASE
        else if (name[0] == CTL_KERN &&
                 name[1] == KERN_OSRELEASE) {
            replacement = DIMDarwinRelease();
        }
#endif

#ifdef KERN_VERSION
        else if (name[0] == CTL_KERN &&
                 name[1] == KERN_VERSION) {
            replacement = DIMFakeKernelVersion();
        }
#endif

        if (replacement.length) {
            return DIMWriteString(
                replacement,
                oldp,
                oldlenp
            );
        }
    }

    if (DIMOriginalSysctl) {
        return DIMOriginalSysctl(
            name,
            namelen,
            oldp,
            oldlenp,
            newp,
            newlen
        );
    }

    errno = ENOSYS;
    return -1;
}

// ============================================================
// SYSCTLNAMETOMIB
// ============================================================

static int DIMHookSysctlNameToMIB(
    const char *name,
    int *mib,
    size_t *size
) {
    if (DIMOriginalSysctlNameToMIB) {
        return DIMOriginalSysctlNameToMIB(
            name,
            mib,
            size
        );
    }

    errno = ENOSYS;
    return -1;
}

// ============================================================
// UNAME
// ============================================================

static int DIMHookUname(struct utsname *info) {
    if (!DIMOriginalUname) {
        errno = ENOSYS;
        return -1;
    }

    int result = DIMOriginalUname(info);

    if (result != 0 || !info) {
        return result;
    }

    NSString *identifier = DIMValue(@"identifier");
    NSString *release = DIMDarwinRelease();
    NSString *kernelVersion = DIMFakeKernelVersion();

    if (identifier.length) {
        strlcpy(
            info->machine,
            identifier.UTF8String,
            sizeof(info->machine)
        );
    }

    if (release.length) {
        strlcpy(
            info->release,
            release.UTF8String,
            sizeof(info->release)
        );
    }

    if (kernelVersion.length) {
        strlcpy(
            info->version,
            kernelVersion.UTF8String,
            sizeof(info->version)
        );
    }

    return result;
}

// ============================================================
// UIDevice METHOD SWIZZLING
// ============================================================

static IMP DIMOriginalDeviceModel = NULL;
static IMP DIMOriginalDeviceLocalizedModel = NULL;
static IMP DIMOriginalDeviceSystemVersion = NULL;

static NSString *DIMDeviceModel(id self, SEL _cmd) {
    NSString *value = DIMValue(@"name");

    if (value.length) {
        return value;
    }

    if (DIMOriginalDeviceModel) {
        return ((id (*)(id, SEL))DIMOriginalDeviceModel)(
            self,
            _cmd
        );
    }

    return @"";
}

static NSString *DIMDeviceLocalizedModel(id self, SEL _cmd) {
    NSString *value = DIMValue(@"name");

    if (value.length) {
        return value;
    }

    if (DIMOriginalDeviceLocalizedModel) {
        return ((id (*)(id, SEL))DIMOriginalDeviceLocalizedModel)(
            self,
            _cmd
        );
    }

    return @"";
}

static NSString *DIMDeviceSystemVersion(id self, SEL _cmd) {
    NSString *value = DIMValue(@"version");

    if (value.length) {
        return value;
    }

    if (DIMOriginalDeviceSystemVersion) {
        return ((id (*)(id, SEL))DIMOriginalDeviceSystemVersion)(
            self,
            _cmd
        );
    }

    return @"";
}

static void DIMInstallUIDeviceHooks(void) {
    Class deviceClass = [UIDevice class];

    Method modelMethod =
        class_getInstanceMethod(
            deviceClass,
            @selector(model)
        );

    Method localizedModelMethod =
        class_getInstanceMethod(
            deviceClass,
            @selector(localizedModel)
        );

    Method systemVersionMethod =
        class_getInstanceMethod(
            deviceClass,
            @selector(systemVersion)
        );

    if (modelMethod) {
        DIMOriginalDeviceModel =
            method_setImplementation(
                modelMethod,
                (IMP)DIMDeviceModel
            );
    }

    if (localizedModelMethod) {
        DIMOriginalDeviceLocalizedModel =
            method_setImplementation(
                localizedModelMethod,
                (IMP)DIMDeviceLocalizedModel
            );
    }

    if (systemVersionMethod) {
        DIMOriginalDeviceSystemVersion =
            method_setImplementation(
                systemVersionMethod,
                (IMP)DIMDeviceSystemVersion
            );
    }
}

// ============================================================
// CONSTRUCTOR
// ============================================================

%ctor {
    @autoreleasepool {
        // Capture the real version before installing hooks.
        DIMOriginalSystemVersion =
            [[UIDevice currentDevice] systemVersion];

        struct DIMRebinding rebindings[] = {
            {
                "sysctlbyname",
                (void *)DIMHookSysctlByName,
                (void **)&DIMOriginalSysctlByName
            },
            {
                "sysctl",
                (void *)DIMHookSysctl,
                (void **)&DIMOriginalSysctl
            },
            {
                "sysctlnametomib",
                (void *)DIMHookSysctlNameToMIB,
                (void **)&DIMOriginalSysctlNameToMIB
            },
            {
                "uname",
                (void *)DIMHookUname,
                (void **)&DIMOriginalUname
            }
        };

        DIMRebindSymbols(
            rebindings,
            sizeof(rebindings) / sizeof(rebindings[0])
        );

        DIMInstallUIDeviceHooks();

        NSString *bundleID =
            NSBundle.mainBundle.bundleIdentifier ?: @"unknown";

        NSDictionary *config =
            DIMActiveConfiguration();

        NSLog(@"[DIM] Runtime loaded: %@", bundleID);

        if (config) {
            NSLog(@"[DIM] Identity active: %@", bundleID);
            NSLog(@"[DIM] Identifier: %@", config[@"identifier"]);
            NSLog(@"[DIM] Product: %@", config[@"name"]);
            NSLog(@"[DIM] Internal name: %@", config[@"board"]);
            NSLog(@"[DIM] iOS: %@", config[@"version"]);
            NSLog(@"[DIM] Build: %@", config[@"build"]);
            NSLog(@"[DIM] Original iOS: %@", DIMOriginalSystemVersion);
        } else {
            NSLog(@"[DIM] Identity inactive: %@", bundleID);
        }
    }
}
