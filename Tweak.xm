
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

#pragma mark - DIM test configuration

#define DIM_TEST_PROFILE 1

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMTargetBundleID = @"ph.telegra.Telegraph";

static NSDictionary *DIMConfiguration = nil;

static NSUInteger DIMImagesScanned = 0;
static NSUInteger DIMLinkeditFound = 0;
static NSUInteger DIMPointerSectionsFound = 0;
static NSUInteger DIMSymbolsReplaced = 0;
static NSUInteger DIMProtectionFailures = 0;
static NSUInteger DIMInvalidImages = 0;

#pragma mark - Original functions

static int (*DIMOriginalSysctlByName)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*DIMOriginalSysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int (*DIMOriginalSysctlNameToMIB)(const char *, int *, size_t *) = NULL;
static int (*DIMOriginalUname)(struct utsname *) = NULL;

#pragma mark - Configuration

static NSDictionary *DIMLoadConfiguration(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];

    if (!prefs) {
        NSLog(@"[DIM] Preferences domain unavailable");
        return nil;
    }

    BOOL enabled = [prefs boolForKey:@"Enabled"];
    BOOL deviceEnabled = [prefs boolForKey:@"DeviceEnabled"];

    if (!enabled || !deviceEnabled) {
        NSLog(@"[DIM] Disabled: Enabled=%d DeviceEnabled=%d", enabled, deviceEnabled);
        return nil;
    }

    BOOL global = [prefs boolForKey:@"GlobalProfileEnabled"];
    BOOL onlyIn = [prefs boolForKey:@"OnlyInEnabled"];

    if (!global && !onlyIn) {
        NSLog(@"[DIM] No application mode enabled");
        return nil;
    }

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";

    // Test profile is deliberately restricted to Telegram.
    if (![bundleID isEqualToString:DIMTargetBundleID]) {
        NSLog(@"[DIM] Not target application: %@", bundleID);
        return nil;
    }

    if (!global && onlyIn) {
        NSArray *selectedApps = [prefs arrayForKey:@"SelectedApps"];

        if (![selectedApps isKindOfClass:NSArray.class] ||
            ![selectedApps containsObject:bundleID]) {
            NSLog(@"[DIM] Telegram is not selected in Only In");
            return nil;
        }
    }

    if (DIM_TEST_PROFILE) {
        NSDictionary *testProfile = @{
            @"identifier": @"iPhone16,2",
            @"name": @"iPhone 15 Pro Max",
            @"board": @"D84AP",
            @"version": @"18.0",
            @"build": @"22A3354",
            @"family": @"iPhone",
            @"darwin": @"24.0.0"
        };

        NSLog(@"[DIM] TEST PROFILE ACTIVE");
        NSLog(@"[DIM] Target process: %@", bundleID);
        NSLog(@"[DIM] Model: %@ (%@)", testProfile[@"name"], testProfile[@"identifier"]);
        NSLog(@"[DIM] iOS %@ (%@), Darwin %@",
              testProfile[@"version"], testProfile[@"build"], testProfile[@"darwin"]);

        return testProfile;
    }

    NSString *identifier = [prefs stringForKey:@"SelectedModel"] ?: @"";
    NSString *version = [prefs stringForKey:@"SelectedVersion"] ?: @"";
    NSString *build = [prefs stringForKey:@"SelectedBuild"] ?: @"";
    NSString *family = [prefs stringForKey:@"DeviceFamily"] ?: @"";

    if (!identifier.length && !version.length && !build.length) {
        NSLog(@"[DIM] Empty profile");
        return nil;
    }

    NSString *marketingName = identifier;
    NSString *board = @"";

    NSArray *devices = [prefs arrayForKey:@"DIMCatalogDevices"];

    if ([devices isKindOfClass:NSArray.class]) {
        for (id candidate in devices) {
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            if (![candidate[@"identifier"] isKindOfClass:NSString.class]) continue;
            if (![candidate[@"identifier"] isEqualToString:identifier]) continue;

            id nameValue = candidate[@"name"];
            if ([nameValue isKindOfClass:NSString.class] && [nameValue length]) {
                marketingName = nameValue;
            }

            id boardValue = candidate[@"boardconfig"];

            if ([boardValue isKindOfClass:NSString.class]) {
                board = boardValue;
            } else if ([boardValue isKindOfClass:NSArray.class]) {
                for (id item in (NSArray *)boardValue) {
                    if ([item isKindOfClass:NSString.class] && [item length]) {
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
    return [value isKindOfClass:NSString.class] ? value : @"";
}

#pragma mark - String helpers

static int DIMWriteString(const char *value, void *oldp, size_t *oldlenp) {
    if (!value) {
        errno = EINVAL;
        return -1;
    }

    size_t required = strlen(value) + 1;

    if (!oldp) {
        if (oldlenp) *oldlenp = required;
        return 0;
    }

    if (!oldlenp) {
        errno = EFAULT;
        return -1;
    }

    size_t available = *oldlenp;
    *oldlenp = required;

    if (available < required) {
        errno = ENOMEM;
        return -1;
    }

    memcpy(oldp, value, required);
    return 0;
}

static int DIMWriteConfiguredString(NSString *key, void *oldp, size_t *oldlenp) {
    NSString *value = DIMValue(key);
    if (!value.length) return 0;
    return DIMWriteString(value.UTF8String, oldp, oldlenp);
}

static void DIMCopyUtsString(char *destination, size_t destinationSize, NSString *value) {
    if (!destination || destinationSize == 0 || !value.length) return;
    strlcpy(destination, value.UTF8String, destinationSize);
}

#pragma mark - Darwin / kernel version

static NSString *DIMDarwinRelease(void) {
    NSString *release = DIMValue(@"darwin");
    return release.length ? release : @"24.0.0";
}

static NSString *DIMFakeKernelVersion(void) {
    struct utsname originalInfo;
    memset(&originalInfo, 0, sizeof(originalInfo));

    if (DIMOriginalUname && DIMOriginalUname(&originalInfo) == 0) {
        NSString *original = [NSString stringWithUTF8String:originalInfo.version];

        if (original.length) {
            NSString *release = DIMDarwinRelease();
            NSRange prefix = [original rangeOfString:@"Darwin Kernel Version "];

            if (prefix.location != NSNotFound) {
                NSUInteger start = NSMaxRange(prefix);
                NSRange colon = [original rangeOfString:@":"
                                                options:0
                                                  range:NSMakeRange(start, original.length - start)];

                if (colon.location != NSNotFound) {
                    NSString *tail = [original substringFromIndex:colon.location];
                    return [NSString stringWithFormat:@"Darwin Kernel Version %@%@", release, tail];
                }
            }
        }
    }

    return [NSString stringWithFormat:
            @"Darwin Kernel Version %@: root:xnu-10000.0.0~1/RELEASE_ARM64_T8112",
            DIMDarwinRelease()];
}

#pragma mark - sysctlbyname

static BOOL DIMHandleSysctlByName(const char *name, void *oldp, size_t *oldlenp) {
    if (!name || !DIMConfiguration) return NO;

    if (strcmp(name, "hw.machine") == 0) {
        DIMWriteConfiguredString(@"identifier", oldp, oldlenp);
        return YES;
    }

    if (strcmp(name, "hw.model") == 0) {
        DIMWriteConfiguredString(@"board", oldp, oldlenp);
        return YES;
    }

    if (strcmp(name, "kern.osversion") == 0) {
        DIMWriteConfiguredString(@"build", oldp, oldlenp);
        return YES;
    }

    if (strcmp(name, "kern.osrelease") == 0) {
        NSString *release = DIMDarwinRelease();
        DIMWriteString(release.UTF8String, oldp, oldlenp);
        return YES;
    }

    if (strcmp(name, "kern.version") == 0) {
        NSString *kernelVersion = DIMFakeKernelVersion();
        DIMWriteString(kernelVersion.UTF8String, oldp, oldlenp);
        return YES;
    }

    return NO;
}

static int DIMHook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                                void *newp, size_t newlen) {
    if (DIMConfiguration && !newp && DIMHandleSysctlByName(name, oldp, oldlenp)) {
        return 0;
    }

    if (!DIMOriginalSysctlByName) {
        errno = ENOSYS;
        return -1;
    }

    return DIMOriginalSysctlByName(name, oldp, oldlenp, newp, newlen);
}

#pragma mark - sysctl MIB

static BOOL DIMMIBEquals(int *name, u_int namelen, int first, int second) {
    return name && namelen == 2 && name[0] == first && name[1] == second;
}

static BOOL DIMHandleSysctlMIB(int *name, u_int namelen, void *oldp, size_t *oldlenp) {
    if (!name || !DIMConfiguration) return NO;

    if (DIMMIBEquals(name, namelen, CTL_HW, HW_MACHINE)) {
        DIMWriteConfiguredString(@"identifier", oldp, oldlenp);
        return YES;
    }

    if (DIMMIBEquals(name, namelen, CTL_HW, HW_MODEL)) {
        DIMWriteConfiguredString(@"board", oldp, oldlenp);
        return YES;
    }

    if (DIMMIBEquals(name, namelen, CTL_KERN, KERN_OSVERSION)) {
        DIMWriteConfiguredString(@"build", oldp, oldlenp);
        return YES;
    }

    if (DIMMIBEquals(name, namelen, CTL_KERN, KERN_OSRELEASE)) {
        NSString *release = DIMDarwinRelease();
        DIMWriteString(release.UTF8String, oldp, oldlenp);
        return YES;
    }

    if (DIMMIBEquals(name, namelen, CTL_KERN, KERN_VERSION)) {
        NSString *kernelVersion = DIMFakeKernelVersion();
        DIMWriteString(kernelVersion.UTF8String, oldp, oldlenp);
        return YES;
    }

    return NO;
}

static int DIMHook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                          void *newp, size_t newlen) {
    if (DIMConfiguration && !newp && DIMHandleSysctlMIB(name, namelen, oldp, oldlenp)) {
        return 0;
    }

    if (!DIMOriginalSysctl) {
        errno = ENOSYS;
        return -1;
    }

    return DIMOriginalSysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

#pragma mark - sysctlnametomib passthrough

static int DIMHook_sysctlnametomib(const char *name, int *mib, size_t *size) {
    if (!DIMOriginalSysctlNameToMIB) {
        errno = ENOSYS;
        return -1;
    }

    return DIMOriginalSysctlNameToMIB(name, mib, size);
}

#pragma mark - uname

static int DIMHook_uname(struct utsname *info) {
    if (!DIMOriginalUname) {
        errno = ENOSYS;
        return -1;
    }

    int result = DIMOriginalUname(info);
    if (result != 0 || !info || !DIMConfiguration) return result;

    DIMCopyUtsString(info->machine, sizeof(info->machine), DIMValue(@"identifier"));
    DIMCopyUtsString(info->release, sizeof(info->release), DIMDarwinRelease());
    DIMCopyUtsString(info->version, sizeof(info->version), DIMFakeKernelVersion());

    return result;
}

#pragma mark - UIDevice swizzling

@interface UIDevice (DIMIdentity)
- (NSString *)dim_hooked_model;
- (NSString *)dim_hooked_localizedModel;
- (NSString *)dim_hooked_systemVersion;
@end

@implementation UIDevice (DIMIdentity)

- (NSString *)dim_hooked_model {
    NSString *name = DIMValue(@"name");
    return name.length ? name : [self dim_hooked_model];
}

- (NSString *)dim_hooked_localizedModel {
    NSString *name = DIMValue(@"name");
    return name.length ? name : [self dim_hooked_localizedModel];
}

- (NSString *)dim_hooked_systemVersion {
    NSString *version = DIMValue(@"version");
    return version.length ? version : [self dim_hooked_systemVersion];
}

@end

static BOOL DIMSwizzleInstanceMethod(Class cls, SEL originalSelector, SEL replacementSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method replacementMethod = class_getInstanceMethod(cls, replacementSelector);

    if (!originalMethod || !replacementMethod) return NO;

    method_exchangeImplementations(originalMethod, replacementMethod);
    return YES;
}

static void DIMInstallUIDeviceHooks(void) {
    Class cls = UIDevice.class;

    BOOL model = DIMSwizzleInstanceMethod(cls, @selector(model), @selector(dim_hooked_model));
    BOOL localized = DIMSwizzleInstanceMethod(cls, @selector(localizedModel),
                                               @selector(dim_hooked_localizedModel));
    BOOL version = DIMSwizzleInstanceMethod(cls, @selector(systemVersion),
                                             @selector(dim_hooked_systemVersion));

    NSLog(@"[DIM] UIDevice hooks: model=%d localized=%d version=%d",
          model, localized, version);

    NSLog(@"[DIM] UIDevice test values: model=%@ localized=%@ iOS=%@",
          UIDevice.currentDevice.model,
          UIDevice.currentDevice.localizedModel,
          UIDevice.currentDevice.systemVersion);
}

#pragma mark - fishhook

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

static BOOL DIMLinkeditRangeValid(uint32_t offset, size_t length,
                                  uint64_t fileoff, uint64_t filesize) {
    if ((uint64_t)offset < fileoff) return NO;

    uint64_t relative = (uint64_t)offset - fileoff;
    if (relative > filesize) return NO;
    if ((uint64_t)length > filesize - relative) return NO;

    return YES;
}

static BOOL DIMMakePointerWritable(void **pointer, vm_prot_t *oldProtection) {
    if (!pointer || !oldProtection) return NO;

    vm_address_t address = (vm_address_t)((uintptr_t)pointer &
                             ~((uintptr_t)vm_page_size - 1));

    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    vm_address_t regionAddress = address;

    kern_return_t kr = vm_region_64(
        mach_task_self(), &regionAddress, &regionSize,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
        &infoCount, &objectName
    );

    if (kr != KERN_SUCCESS) {
        DIMProtectionFailures++;
        return NO;
    }

    *oldProtection = info.protection;

    vm_prot_t writableProtection =
        info.protection | VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY;

    kr = vm_protect(mach_task_self(), address, vm_page_size,
                    FALSE, writableProtection);

    if (kr != KERN_SUCCESS) {
        DIMProtectionFailures++;
        return NO;
    }

    return YES;
}

static void DIMRestorePointerProtection(void **pointer, vm_prot_t oldProtection) {
    if (!pointer) return;

    vm_address_t address = (vm_address_t)((uintptr_t)pointer &
                             ~((uintptr_t)vm_page_size - 1));

    vm_protect(mach_task_self(), address, vm_page_size, FALSE, oldProtection);
}

static void DIMRebindImage(const struct mach_header *header, intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) {
        DIMInvalidImages++;
        return;
    }

    DIMImagesScanned++;

    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
    const struct load_command *command =
        (const struct load_command *)(header64 + 1);

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;

    uintptr_t commandStart = (uintptr_t)command;
    uintptr_t commandEnd = commandStart + header64->sizeofcmds;

    for (uint32_t i = 0; i < header64->ncmds; i++) {
        if ((uintptr_t)command + sizeof(struct load_command) > commandEnd) {
            DIMInvalidImages++;
            return;
        }

        if (command->cmdsize < sizeof(struct load_command) ||
            (uintptr_t)command + command->cmdsize > commandEnd) {
            DIMInvalidImages++;
            return;
        }

        if (command->cmd == LC_SYMTAB &&
            command->cmdsize >= sizeof(struct symtab_command)) {
            symtab = (const struct symtab_command *)command;
        }

        if (command->cmd == LC_DYSYMTAB &&
            command->cmdsize >= sizeof(struct dysymtab_command)) {
            dysymtab = (const struct dysymtab_command *)command;
        }

        if (command->cmd == LC_SEGMENT_64 &&
            command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;

            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkedit = segment;
            }
        }

        command = (const struct load_command *)((uintptr_t)command + command->cmdsize);
    }

    if (!symtab || !dysymtab || !linkedit) return;

    DIMLinkeditFound++;

    if (!DIMLinkeditRangeValid(symtab->symoff,
            (size_t)symtab->nsyms * sizeof(struct nlist_64),
            linkedit->fileoff, linkedit->filesize) ||
        !DIMLinkeditRangeValid(symtab->stroff, symtab->strsize,
            linkedit->fileoff, linkedit->filesize) ||
        !DIMLinkeditRangeValid(dysymtab->indirectsymoff,
            (size_t)dysymtab->nindirectsyms * sizeof(uint32_t),
            linkedit->fileoff, linkedit->filesize)) {
        DIMInvalidImages++;
        return;
    }

    uintptr_t linkeditBase = (uintptr_t)slide +
                             (uintptr_t)linkedit->vmaddr -
                             (uintptr_t)linkedit->fileoff;

    struct nlist_64 *symbols =
        (struct nlist_64 *)(linkeditBase + symtab->symoff);
    char *strings = (char *)(linkeditBase + symtab->stroff);
    uint32_t *indirectSymbols =
        (uint32_t *)(linkeditBase + dysymtab->indirectsymoff);

    command = (const struct load_command *)(header64 + 1);

    for (uint32_t i = 0; i < header64->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            const struct section_64 *section =
                (const struct section_64 *)(segment + 1);

            if (segment->nsects >
                (command->cmdsize - sizeof(struct segment_command_64)) /
                sizeof(struct section_64)) {
                DIMInvalidImages++;
                return;
            }

            for (uint32_t sectionIndex = 0;
                 sectionIndex < segment->nsects; sectionIndex++) {

                uint32_t sectionType = section[sectionIndex].flags & SECTION_TYPE;

                if (sectionType != S_LAZY_SYMBOL_POINTERS &&
                    sectionType != S_NON_LAZY_SYMBOL_POINTERS) {
                    continue;
                }

                DIMPointerSectionsFound++;

                uint32_t pointerCount = (uint32_t)(
                    section[sectionIndex].size / sizeof(void *)
                );

                uint32_t indirectIndex = section[sectionIndex].reserved1;

                if (indirectIndex > dysymtab->nindirectsyms ||
                    pointerCount > dysymtab->nindirectsyms - indirectIndex) {
                    DIMInvalidImages++;
                    continue;
                }

                void **bindings = (void **)(slide + section[sectionIndex].addr);

                for (uint32_t pointerIndex = 0;
                     pointerIndex < pointerCount; pointerIndex++) {

                    uint32_t symbolIndex =
                        indirectSymbols[indirectIndex + pointerIndex];

                    if (symbolIndex == INDIRECT_SYMBOL_ABS ||
                        symbolIndex == INDIRECT_SYMBOL_LOCAL ||
                        symbolIndex == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
                        continue;
                    }

                    if (symbolIndex >= symtab->nsyms) continue;

                    uint32_t stringIndex = symbols[symbolIndex].n_un.n_strx;
                    if (stringIndex >= symtab->strsize) continue;

                    const char *symbolName = strings + stringIndex;
                    if (!symbolName || symbolName[0] != '_') continue;

                    symbolName++;

                    for (struct DIMRebindingsEntry *entry = DIMRebindingsHead;
                         entry; entry = entry->next) {

                        for (size_t bindingIndex = 0;
                             bindingIndex < entry->count; bindingIndex++) {

                            struct DIMRebinding *rebinding =
                                &entry->rebindings[bindingIndex];

                            if (strcmp(symbolName, rebinding->name) != 0) continue;

                            void **slot = &bindings[pointerIndex];

                            if (rebinding->replaced &&
                                *rebinding->replaced == NULL) {
                                *rebinding->replaced = *slot;
                            }

                            if (*slot != rebinding->replacement) {
                                vm_prot_t oldProtection = 0;

                                if (DIMMakePointerWritable(slot, &oldProtection)) {
                                    *slot = rebinding->replacement;
                                    DIMRestorePointerProtection(slot, oldProtection);
                                    DIMSymbolsReplaced++;
                                }
                            }
                        }
                    }
                }
            }
        }

        command = (const struct load_command *)((uintptr_t)command + command->cmdsize);
    }
}

static void DIMAddImage(const struct mach_header *header, intptr_t slide) {
    DIMRebindImage(header, slide);
}

static int DIMRebindSymbols(struct DIMRebinding rebindings[], size_t count) {
    if (!rebindings || count == 0) return -1;

    // Explicit casts are required because Tweak.xm is compiled as Objective-C++.
    struct DIMRebindingsEntry *entry =
        (struct DIMRebindingsEntry *)calloc(
            1, sizeof(struct DIMRebindingsEntry)
        );

    if (!entry) return -1;

    entry->rebindings =
        (struct DIMRebinding *)calloc(
            count, sizeof(struct DIMRebinding)
        );

    if (!entry->rebindings) {
        free(entry);
        return -1;
    }

    memcpy(entry->rebindings, rebindings, count * sizeof(struct DIMRebinding));

    entry->count = count;
    entry->next = NULL;

    if (!DIMRebindingsHead) {
        DIMRebindingsHead = entry;
    } else {
        struct DIMRebindingsEntry *tail = DIMRebindingsHead;

        while (tail->next) tail = tail->next;
        tail->next = entry;
    }

    _dyld_register_func_for_add_image(DIMAddImage);
    return 0;
}

#pragma mark - Install hooks

static void DIMInstallFishhook(void) {
    struct DIMRebinding rebindings[] = {
        {"sysctlbyname", (void *)DIMHook_sysctlbyname, (void **)&DIMOriginalSysctlByName},
        {"sysctl", (void *)DIMHook_sysctl, (void **)&DIMOriginalSysctl},
        {"sysctlnametomib", (void *)DIMHook_sysctlnametomib, (void **)&DIMOriginalSysctlNameToMIB},
        {"uname", (void *)DIMHook_uname, (void **)&DIMOriginalUname}
    };

    int result = DIMRebindSymbols(
        rebindings,
        sizeof(rebindings) / sizeof(rebindings[0])
    );

    NSLog(@"[DIM] fishhook registration result=%d", result);
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSLog(@"[DIM] Loaded in process: %@", bundleID);

        DIMConfiguration = DIMLoadConfiguration();

        if (!DIMConfiguration) {
            NSLog(@"[DIM] No active configuration; hooks not installed");
            return;
        }

        DIMInstallFishhook();
        DIMInstallUIDeviceHooks();

        NSLog(@"[DIM] Installation complete");
        NSLog(@"[DIM] Profile: %@ / %@ / %@ (%@)",
              DIMValue(@"name"),
              DIMValue(@"identifier"),
              DIMValue(@"version"),
              DIMValue(@"build"));

        NSLog(@"[DIM] Fishhook stats: images=%lu linkedit=%lu "
              "sections=%lu replaced=%lu protectionFailures=%lu invalid=%lu",
              (unsigned long)DIMImagesScanned,
              (unsigned long)DIMLinkeditFound,
              (unsigned long)DIMPointerSectionsFound,
              (unsigned long)DIMSymbolsReplaced,
              (unsigned long)DIMProtectionFailures,
              (unsigned long)DIMInvalidImages);
    }
}
