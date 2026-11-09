
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

#import <mach/mach.h>
#import <mach/mach_error.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <stdio.h>
#import <errno.h>

static NSString * const DIMDomain = @"com.dim.manager";

static NSDictionary *DIMConfiguration = nil;
static NSString *DIMOriginalSystemVersion = nil;

// ============================================================
// ORIGINAL FUNCTIONS
// ============================================================

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

// ============================================================
// CONFIGURATION
// ============================================================

static NSDictionary *DIMLoadConfiguration(void) {
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

    if (!global && onlyIn) {
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

    NSString *marketingName = identifier;
    NSString *board = @"";

    NSArray *devices =
        [prefs arrayForKey:@"DIMCatalogDevices"];

    if ([devices isKindOfClass:NSArray.class]) {
        for (id candidate in devices) {
            if (![candidate isKindOfClass:NSDictionary.class]) {
                continue;
            }

            if (![candidate[@"identifier"] isKindOfClass:NSString.class]) {
                continue;
            }

            if (![candidate[@"identifier"] isEqualToString:identifier]) {
                continue;
            }

            id nameValue = candidate[@"name"];

            if ([nameValue isKindOfClass:NSString.class] &&
                [nameValue length]) {
                marketingName = nameValue;
            }

            id boardValue = candidate[@"boardconfig"];

            if ([boardValue isKindOfClass:NSString.class]) {
                board = boardValue;
            } else if ([boardValue isKindOfClass:NSArray.class]) {
                for (id item in (NSArray *)boardValue) {
                    if ([item isKindOfClass:NSString.class] &&
                        [item length]) {
                        board = item;
                        break;
                    }
                }
            }

            break;
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
    id value = DIMConfiguration[key];

    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }

    return [value length] ? value : nil;
}

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

static BOOL DIMRangeValid(
    size_t offset,
    size_t length,
    size_t total
) {
    return offset <= total && length <= total - offset;
}

static BOOL DIMProtectAddress(void *address) {
    if (!address || vm_page_size == 0) {
        return NO;
    }

    vm_address_t location = (vm_address_t)(uintptr_t)address;

    vm_address_t page =
        location & ~((vm_address_t)vm_page_size - 1);

    kern_return_t result = vm_protect(
        mach_task_self(),
        page,
        vm_page_size,
        false,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
    );

    return result == KERN_SUCCESS;
}

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

    if (!symtab->nsyms ||
        !symtab->strsize ||
        !dysymtab->nindirectsyms ||
        !linkedit->filesize) {
        return;
    }

    uintptr_t linkeditBase =
        (uintptr_t)slide +
        (uintptr_t)linkedit->vmaddr -
        (uintptr_t)linkedit->fileoff;

    if (!linkeditBase) {
        return;
    }

    if (!DIMRangeValid(
        symtab->symoff,
        (size_t)symtab->nsyms * sizeof(struct nlist_64),
        (size_t)linkedit->filesize
    )) {
        return;
    }

    if (!DIMRangeValid(
        symtab->stroff,
        symtab->strsize,
        (size_t)linkedit->filesize
    )) {
        return;
    }

    if (!DIMRangeValid(
        dysymtab->indirectsymoff,
        (size_t)dysymtab->nindirectsyms * sizeof(uint32_t),
        (size_t)linkedit->filesize
    )) {
        return;
    }

    struct nlist_64 *symbols =
        (struct nlist_64 *)(linkeditBase + symtab->symoff);

    char *strings =
        (char *)(linkeditBase + symtab->stroff);

    uint32_t *indirect =
        (uint32_t *)(linkeditBase + dysymtab->indirectsymoff);

    struct load_command *command =
        (struct load_command *)(
            (uintptr_t)header + sizeof(struct mach_header_64)
        );

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmdsize < sizeof(struct load_command)) {
            return;
        }

        if (command->cmd == LC_SEGMENT_64 &&
            command->cmdsize >= sizeof(struct segment_command_64)) {

            struct segment_command_64 *segment =
                (struct segment_command_64 *)command;

            size_t sectionsSize =
                (size_t)segment->nsects * sizeof(struct section_64);

            if (!DIMRangeValid(
                sizeof(struct segment_command_64),
                sectionsSize,
                command->cmdsize
            )) {
                command = (struct load_command *)(
                    (uintptr_t)command + command->cmdsize
                );
                continue;
            }

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

                if (sections[j].size == 0 ||
                    sections[j].size % sizeof(uintptr_t) != 0) {
                    continue;
                }

                uintptr_t *bindings =
                    (uintptr_t *)(slide + sections[j].addr);

                uint32_t count =
                    (uint32_t)(
                        sections[j].size / sizeof(uintptr_t)
                    );

                if (sections[j].reserved1 >
                    dysymtab->nindirectsyms) {
                    continue;
                }

                if (count >
                    dysymtab->nindirectsyms - sections[j].reserved1) {
                    continue;
                }

                for (uint32_t k = 0; k < count; k++) {
                    uint32_t index =
                        indirect[sections[j].reserved1 + k];

                    if (index == INDIRECT_SYMBOL_ABS ||
                        index == INDIRECT_SYMBOL_LOCAL ||
                        index == (INDIRECT_SYMBOL_LOCAL |
                                  INDIRECT_SYMBOL_ABS)) {
                        continue;
                    }

                    if (index >= symtab->nsyms) {
                        continue;
                    }

                    uint32_t stringIndex =
                        symbols[index].n_un.n_strx;

                    if (stringIndex >= symtab->strsize) {
                        continue;
                    }

                    const char *symbolName =
                        strings + stringIndex;

                    size_t remaining =
                        symtab->strsize - stringIndex;

                    if (!memchr(symbolName, '\0', remaining) ||
                        symbolName[0] != '_') {
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

                            void *original =
                                (void *)(uintptr_t)bindings[k];

                            if (binding->replaced &&
                                !*binding->replaced &&
                                original != binding->replacement) {
                                *binding->replaced = original;
                            }

                            if (original == binding->replacement) {
                                continue;
                            }

                            if (!DIMProtectAddress(&bindings[k])) {
                                continue;
                            }

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
            (uintptr_t)header64 + sizeof(struct mach_header_64)
        );

    for (uint32_t i = 0; i < header64->ncmds; i++) {
        if (command->cmdsize < sizeof(struct load_command)) {
            return;
        }

        if (command->cmd == LC_SEGMENT_64 &&
            command->cmdsize >= sizeof(struct segment_command_64)) {

            struct segment_command_64 *segment =
                (struct segment_command_64 *)command;

            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkedit = segment;
            }
        } else if (command->cmd == LC_SYMTAB &&
                   command->cmdsize >= sizeof(struct symtab_command)) {
            symtab = (struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB &&
                   command->cmdsize >= sizeof(struct dysymtab_command)) {
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
    if (!rebindings || count == 0) {
        return -1;
    }

    struct DIMRebindingsEntry *entry =
        (struct DIMRebindingsEntry *)calloc(
            1,
            sizeof(struct DIMRebindingsEntry)
        );

    if (!entry) {
        return -1;
    }

    entry->rebindings =
        (struct DIMRebinding *)calloc(
            count,
            sizeof(struct DIMRebinding)
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
// ORIGINAL KERNEL STRINGS
// ============================================================

static NSString *DIMOriginalKernelString(int mibValue) {
    if (!DIMOriginalSysctl) {
        return nil;
    }

    int mib[2] = {
        CTL_KERN,
        mibValue
    };

    size_t size = 0;

    if (DIMOriginalSysctl(
        mib,
        2,
        NULL,
        &size,
        NULL,
        0
    ) != 0 || size == 0 || size > 65536) {
        return nil;
    }

    char *buffer = (char *)calloc(1, size + 1);

    if (!buffer) {
        return nil;
    }

    NSString *result = nil;

    if (DIMOriginalSysctl(
        mib,
        2,
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

static NSString *DIMOriginalDarwinRelease(void) {
#ifdef KERN_OSRELEASE
    return DIMOriginalKernelString(KERN_OSRELEASE);
#else
    return nil;
#endif
}

static NSString *DIMOriginalKernelVersion(void) {
#ifdef KERN_VERSION
    return DIMOriginalKernelString(KERN_VERSION);
#else
    return nil;
#endif
}

// ============================================================
// DARWIN RELEASE
// ============================================================

static NSString *DIMDarwinRelease(void) {
    NSString *version = DIMValue(@"version");

    if (!version.length) {
        return DIMOriginalDarwinRelease();
    }

    NSArray *parts =
        [version componentsSeparatedByString:@"."];

    NSInteger major =
        parts.count > 0 ? [parts[0] integerValue] : 0;

    if (major <= 0) {
        return DIMOriginalDarwinRelease();
    }

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

static NSString *DIMFakeKernelVersion(void) {
    NSString *original = DIMOriginalKernelVersion();
    NSString *release = DIMDarwinRelease();

    if (!original.length || !release.length) {
        return original;
    }

    NSString *prefixText = @"Darwin Kernel Version ";

    NSRange prefix =
        [original rangeOfString:prefixText];

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
// UIDevice SWIZZLING
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
        NSString *bundleID =
            NSBundle.mainBundle.bundleIdentifier ?: @"unknown";

        // Load configuration before installing any hooks.
        DIMConfiguration = DIMLoadConfiguration();

        if (!DIMConfiguration) {
            NSLog(@"[DIM] Not selected: %@", bundleID);
            return;
        }

        // Capture original version before UIDevice swizzling.
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

        int result = DIMRebindSymbols(
            rebindings,
            sizeof(rebindings) / sizeof(rebindings[0])
        );

        DIMInstallUIDeviceHooks();

        NSLog(@"[DIM] Runtime loaded: %@", bundleID);
        NSLog(@"[DIM] Fishhook result: %d", result);
        NSLog(@"[DIM] Identity active: %@", bundleID);
        NSLog(@"[DIM] Identifier: %@", DIMValue(@"identifier"));
        NSLog(@"[DIM] Product: %@", DIMValue(@"name"));
        NSLog(@"[DIM] Internal name: %@", DIMValue(@"board"));
        NSLog(@"[DIM] iOS: %@", DIMValue(@"version"));
        NSLog(@"[DIM] Build: %@", DIMValue(@"build"));
        NSLog(@"[DIM] Original iOS: %@", DIMOriginalSystemVersion);
    }
}
