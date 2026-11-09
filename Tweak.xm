
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

#import <errno.h>
#import <stdint.h>
#import <stdbool.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// ============================================================
// DIM CONFIGURATION
// ============================================================

#define DIM_TEST_PROFILE 1

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMTargetBundleID = @"ph.telegra.Telegraph";

// ============================================================
// TEST PROFILE: iPhone 15 Pro Max / iOS 18.0
// ============================================================

#if DIM_TEST_PROFILE

static NSString * const DIMDeviceIdentifier = @"iPhone16,2";
static NSString * const DIMDeviceInternalName = @"D84AP";
static NSString * const DIMDeviceProduct = @"iPhone 15 Pro Max";

static NSString * const DIMSystemVersion = @"18.0";
static NSString * const DIMBuildVersion = @"22A3354";
static NSString * const DIMDarwinVersion = @"24.0.0";

static NSString * const DIMDeviceFamily = @"iPhone";

#endif

// ============================================================
// ORIGINAL FUNCTIONS
// ============================================================

typedef int (*DIMSysctlFunction)(
    int *,
    u_int,
    void *,
    size_t *,
    void *,
    size_t
);

typedef int (*DIMSysctlByNameFunction)(
    const char *,
    void *,
    size_t *,
    void *,
    size_t
);

typedef int (*DIMSysctlNameToMIBFunction)(
    const char *,
    int *,
    size_t *
);

typedef int (*DIMUnameFunction)(struct utsname *);

static DIMSysctlFunction DIMOriginalSysctl = NULL;
static DIMSysctlByNameFunction DIMOriginalSysctlByName = NULL;
static DIMSysctlNameToMIBFunction DIMOriginalSysctlNameToMIB = NULL;
static DIMUnameFunction DIMOriginalUname = NULL;

// ============================================================
// ORIGINAL KERNEL INFORMATION
// ============================================================

static NSString *DIMOriginalDarwinRelease = nil;
static NSString *DIMOriginalKernelVersion = nil;
static NSString *DIMFakeKernelVersionValue = nil;

// ============================================================
// PREFERENCE HELPERS
// ============================================================

static id DIMCopyPreference(NSString *key) {
    if (!key) {
        return nil;
    }

    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)DIMDomain
    );

    if (!value) {
        return nil;
    }

    return CFBridgingRelease(value);
}

static BOOL DIMPreferenceBool(NSString *key) {
    id value = DIMCopyPreference(key);

    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }

    return NO;
}

static NSArray *DIMSelectedApplications(void) {
    id value = DIMCopyPreference(@"SelectedApps");

    if ([value isKindOfClass:[NSArray class]]) {
        return value;
    }

    return @[];
}

// ============================================================
// APPLICATION FILTER
// ============================================================

static BOOL DIMShouldRunInCurrentApplication(void) {
    @autoreleasepool {
        CFPreferencesAppSynchronize(
            (__bridge CFStringRef)DIMDomain
        );

        if (!DIMPreferenceBool(@"Enabled")) {
            return NO;
        }

        if (!DIMPreferenceBool(@"DeviceEnabled")) {
            return NO;
        }

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        if (bundleID.length == 0) {
            return NO;
        }

        // Test profile is intentionally restricted to Telegram.
        if (![bundleID isEqualToString:DIMTargetBundleID]) {
            return NO;
        }

        BOOL globalEnabled =
            DIMPreferenceBool(@"GlobalProfileEnabled");

        BOOL onlyInEnabled =
            DIMPreferenceBool(@"OnlyInEnabled");

        if (globalEnabled) {
            return YES;
        }

        if (onlyInEnabled) {
            NSArray *selectedApps = DIMSelectedApplications();

            return [selectedApps containsObject:bundleID];
        }

        return NO;
    }
}

// ============================================================
// KERNEL VERSION GENERATION
// ============================================================

static void DIMCaptureOriginalKernelInformation(void) {
    struct utsname info;

    memset(&info, 0, sizeof(info));

    if (uname(&info) != 0) {
        return;
    }

    DIMOriginalDarwinRelease =
        [NSString stringWithUTF8String:info.release];

    DIMOriginalKernelVersion =
        [NSString stringWithUTF8String:info.version];
}

static NSString *DIMFakeKernelVersion(void) {
    if (DIMFakeKernelVersionValue.length > 0) {
        return DIMFakeKernelVersionValue;
    }

    NSString *original = DIMOriginalKernelVersion;
    NSString *originalRelease = DIMOriginalDarwinRelease;

    if (original.length == 0) {
        return nil;
    }

    if (originalRelease.length > 0) {
        DIMFakeKernelVersionValue =
            [original stringByReplacingOccurrencesOfString:originalRelease
                                                withString:DIMDarwinVersion];
    } else {
        DIMFakeKernelVersionValue = original;
    }

    return DIMFakeKernelVersionValue;
}

// ============================================================
// STRING HELPERS
// ============================================================

static int DIMReturnSysctlString(
    const char *value,
    void *oldp,
    size_t *oldlenp
) {
    if (!value) {
        errno = EINVAL;
        return -1;
    }

    size_t requiredLength = strlen(value) + 1;

    if (oldp == NULL) {
        if (oldlenp != NULL) {
            *oldlenp = requiredLength;
            return 0;
        }

        errno = EFAULT;
        return -1;
    }

    if (oldlenp == NULL) {
        errno = EFAULT;
        return -1;
    }

    if (*oldlenp == 0) {
        return -2;
    }

    // Matches UCFlag's strncpy-style return behavior.
    strncpy((char *)oldp, value, *oldlenp);

    return 0;
}

static const char *DIMValueForSysctlName(const char *name) {
    if (!name) {
        return NULL;
    }

    if (strcmp(name, "hw.machine") == 0) {
        return DIMDeviceIdentifier.UTF8String;
    }

    if (strcmp(name, "hw.model") == 0) {
        return DIMDeviceInternalName.UTF8String;
    }

    if (strcmp(name, "kern.osrelease") == 0) {
        return DIMDarwinVersion.UTF8String;
    }

    if (strcmp(name, "kern.osversion") == 0) {
        return DIMBuildVersion.UTF8String;
    }

    if (strcmp(name, "kern.version") == 0) {
        return DIMFakeKernelVersion().UTF8String;
    }

    return NULL;
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
    const char *replacement = DIMValueForSysctlName(name);

    if (replacement != NULL) {
        int result = DIMReturnSysctlString(
            replacement,
            oldp,
            oldlenp
        );

        if (result != -2) {
            return result;
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
// SYSCTL NUMERIC MIB
// ============================================================

#ifndef KERN_OSVERSION
#define KERN_OSVERSION 65
#endif

static const char *DIMValueForMIB(
    int *name,
    u_int namelen
) {
    if (!name || namelen != 2) {
        return NULL;
    }

    if (name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE) {
            return DIMDeviceIdentifier.UTF8String;
        }

        if (name[1] == HW_MODEL) {
            return DIMDeviceInternalName.UTF8String;
        }
    }

    if (name[0] == CTL_KERN) {
        if (name[1] == KERN_OSRELEASE) {
            return DIMDarwinVersion.UTF8String;
        }

        if (name[1] == KERN_VERSION) {
            return DIMFakeKernelVersion().UTF8String;
        }

        if (name[1] == KERN_OSVERSION) {
            return DIMBuildVersion.UTF8String;
        }
    }

    return NULL;
}

static int DIMHookSysctl(
    int *name,
    u_int namelen,
    void *oldp,
    size_t *oldlenp,
    void *newp,
    size_t newlen
) {
    const char *replacement = DIMValueForMIB(name, namelen);

    if (replacement != NULL) {
        int result = DIMReturnSysctlString(
            replacement,
            oldp,
            oldlenp
        );

        if (result != -2) {
            return result;
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
// UCFlag rebinds this symbol but passes through to original.
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

    strlcpy(
        info->machine,
        DIMDeviceIdentifier.UTF8String,
        sizeof(info->machine)
    );

    strlcpy(
        info->release,
        DIMDarwinVersion.UTF8String,
        sizeof(info->release)
    );

    NSString *kernelVersion = DIMFakeKernelVersion();

    if (kernelVersion.length > 0) {
        strlcpy(
            info->version,
            kernelVersion.UTF8String,
            sizeof(info->version)
        );
    }

    return result;
}

// ============================================================
// FISHHOOK DATA STRUCTURES
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
static BOOL DIMFishhookRegistered = NO;

// ============================================================
// FISHHOOK LINKEDIT VALIDATION
// ============================================================

static BOOL DIMLinkeditRangeValid(
    uint64_t offset,
    uint64_t length,
    uint64_t fileoff,
    uint64_t filesize
) {
    if (offset < fileoff) {
        return NO;
    }

    uint64_t relativeOffset = offset - fileoff;

    if (relativeOffset > filesize) {
        return NO;
    }

    if (length > filesize - relativeOffset) {
        return NO;
    }

    return YES;
}

// ============================================================
// FISHHOOK POINTER PROTECTION
// ============================================================

static BOOL DIMMakePointerWritable(
    void **bindings,
    size_t count
) {
    if (!bindings || count == 0) {
        return NO;
    }

    size_t pageSize = (size_t)getpagesize();

    if (pageSize == 0) {
        return NO;
    }

    uintptr_t start = (uintptr_t)bindings;
    uintptr_t end = start + count * sizeof(void *);

    if (end < start) {
        return NO;
    }

    uintptr_t pageStart = start & ~(uintptr_t)(pageSize - 1);
    uintptr_t pageEnd =
        (end + pageSize - 1) & ~(uintptr_t)(pageSize - 1);

    if (pageEnd <= pageStart) {
        return NO;
    }

    kern_return_t kr = vm_protect(
        mach_task_self(),
        (vm_address_t)pageStart,
        (vm_size_t)(pageEnd - pageStart),
        false,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
    );

    return kr == KERN_SUCCESS;
}

// ============================================================
// FISHHOOK SECTION REBINDING
// ============================================================

static void DIMPerformRebindingWithSection(
    struct section_64 *section,
    intptr_t slide,
    struct DIMRebinding *rebindings,
    size_t rebindingsCount,
    struct nlist_64 *symbols,
    char *strings,
    uint32_t *indirectSymbols,
    uint32_t indirectSymbolCount
) {
    if (!section ||
        !rebindings ||
        !symbols ||
        !strings ||
        !indirectSymbols) {
        return;
    }

    uint32_t sectionType =
        section->flags & SECTION_TYPE;

    if (sectionType != S_LAZY_SYMBOL_POINTERS &&
        sectionType != S_NON_LAZY_SYMBOL_POINTERS) {
        return;
    }

    size_t pointerCount =
        (size_t)(section->size / sizeof(void *));

    if (pointerCount == 0) {
        return;
    }

    if (section->reserved1 >= indirectSymbolCount) {
        return;
    }

    if (pointerCount >
        (size_t)(indirectSymbolCount - section->reserved1)) {
        return;
    }

    void **bindings = (void **)(
        (uintptr_t)slide + (uintptr_t)section->addr
    );

    if (!bindings) {
        return;
    }

    if (!DIMMakePointerWritable(bindings, pointerCount)) {
        return;
    }

    for (size_t i = 0; i < pointerCount; i++) {
        uint32_t symbolIndex =
            indirectSymbols[section->reserved1 + i];

        if (symbolIndex == INDIRECT_SYMBOL_ABS ||
            symbolIndex == INDIRECT_SYMBOL_LOCAL ||
            symbolIndex == (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) {
            continue;
        }

        if (symbolIndex >= indirectSymbolCount) {
            continue;
        }

        struct nlist_64 *symbol = &symbols[symbolIndex];

        uint32_t stringIndex = symbol->n_un.n_strx;

        if (stringIndex == 0) {
            continue;
        }

        const char *symbolName = strings + stringIndex;

        if (!symbolName || symbolName[0] != '_') {
            continue;
        }

        symbolName++;

        for (size_t j = 0; j < rebindingsCount; j++) {
            if (!rebindings[j].name ||
                !rebindings[j].replacement) {
                continue;
            }

            if (strcmp(symbolName, rebindings[j].name) != 0) {
                continue;
            }

            if (rebindings[j].replaced &&
                *rebindings[j].replaced == NULL) {
                *rebindings[j].replaced = bindings[i];
            }

            bindings[i] = rebindings[j].replacement;
            break;
        }
    }
}

// ============================================================
// FISHHOOK IMAGE REBINDING
// ============================================================

static void DIMRebindSymbolsForImage(
    const struct mach_header *header,
    intptr_t slide
) {
    if (!header || header->magic != MH_MAGIC_64) {
        return;
    }

    const struct mach_header_64 *header64 =
        (const struct mach_header_64 *)header;

    struct symtab_command *symtab = NULL;
    struct dysymtab_command *dysymtab = NULL;
    struct segment_command_64 *linkedit = NULL;

    const uint8_t *commandPointer =
        (const uint8_t *)header64 + sizeof(struct mach_header_64);

    for (uint32_t i = 0; i < header64->ncmds; i++) {
        struct load_command *command =
            (struct load_command *)commandPointer;

        if (command->cmdsize < sizeof(struct load_command)) {
            return;
        }

        if (command->cmd == LC_SYMTAB &&
            command->cmdsize >= sizeof(struct symtab_command)) {
            symtab = (struct symtab_command *)command;
        }

        if (command->cmd == LC_DYSYMTAB &&
            command->cmdsize >= sizeof(struct dysymtab_command)) {
            dysymtab = (struct dysymtab_command *)command;
        }

        if (command->cmd == LC_SEGMENT_64 &&
            command->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *segment =
                (struct segment_command_64 *)command;

            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkedit = segment;
            }
        }

        commandPointer += command->cmdsize;
    }

    if (!symtab || !dysymtab || !linkedit) {
        return;
    }

    if (symtab->nsyms == 0 ||
        dysymtab->nindirectsyms == 0 ||
        symtab->strsize == 0) {
        return;
    }

    uint64_t symbolBytes =
        (uint64_t)symtab->nsyms * sizeof(struct nlist_64);

    uint64_t indirectBytes =
        (uint64_t)dysymtab->nindirectsyms * sizeof(uint32_t);

    if (!DIMLinkeditRangeValid(
            symtab->symoff,
            symbolBytes,
            linkedit->fileoff,
            linkedit->filesize)) {
        return;
    }

    if (!DIMLinkeditRangeValid(
            symtab->stroff,
            symtab->strsize,
            linkedit->fileoff,
            linkedit->filesize)) {
        return;
    }

    if (!DIMLinkeditRangeValid(
            dysymtab->indirectsymoff,
            indirectBytes,
            linkedit->fileoff,
            linkedit->filesize)) {
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

    uint32_t *indirectSymbols =
        (uint32_t *)(linkeditBase + dysymtab->indirectsymoff);

    struct DIMRebindingsEntry *entry = DIMRebindingsHead;

    while (entry) {
        commandPointer =
            (const uint8_t *)header64 + sizeof(struct mach_header_64);

        for (uint32_t i = 0; i < header64->ncmds; i++) {
            struct load_command *command =
                (struct load_command *)commandPointer;

            if (command->cmd == LC_SEGMENT_64 &&
                command->cmdsize >= sizeof(struct segment_command_64)) {
                struct segment_command_64 *segment =
                    (struct segment_command_64 *)command;

                if (command->cmdsize >=
                    sizeof(struct segment_command_64) +
                    segment->nsects * sizeof(struct section_64)) {

                    struct section_64 *sections =
                        (struct section_64 *)(
                            (uint8_t *)segment +
                            sizeof(struct segment_command_64)
                        );

                    for (uint32_t sectionIndex = 0;
                         sectionIndex < segment->nsects;
                         sectionIndex++) {

                        DIMPerformRebindingWithSection(
                            &sections[sectionIndex],
                            slide,
                            entry->rebindings,
                            entry->count,
                            symbols,
                            strings,
                            indirectSymbols,
                            dysymtab->nindirectsyms
                        );
                    }
                }
            }

            commandPointer += command->cmdsize;
        }

        entry = entry->next;
    }
}

// ============================================================
// FISHHOOK IMAGE CALLBACK
// ============================================================

static void DIMRebindImageCallback(
    const struct mach_header *header,
    intptr_t slide
) {
    DIMRebindSymbolsForImage(header, slide);
}

// ============================================================
// FISHHOOK prepend_rebindings
// ============================================================

static int DIMPrependRebindings(
    struct DIMRebindingsEntry **head,
    struct DIMRebinding rebindings[],
    size_t count
) {
    if (!head || !rebindings || count == 0) {
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
        count * sizeof(struct DIMRebinding)
    );

    entry->count = count;
    entry->next = *head;
    *head = entry;

    return 0;
}

// ============================================================
// FISHHOOK rebind_symbols
// ============================================================

static int DIMRebindSymbols(
    struct DIMRebinding rebindings[],
    size_t count
) {
    if (DIMPrependRebindings(
            &DIMRebindingsHead,
            rebindings,
            count
        ) < 0) {
        return -1;
    }

    if (!DIMFishhookRegistered) {
        DIMFishhookRegistered = YES;

        // Registers callback and processes already loaded images.
        _dyld_register_func_for_add_image(
            DIMRebindImageCallback
        );
    }

    return 0;
}

// ============================================================
// UIDevice SWIZZLING
// ============================================================

static NSString *DIMHookDeviceModel(
    id self,
    SEL command
) {
    return DIMDeviceProduct;
}

static NSString *DIMHookLocalizedModel(
    id self,
    SEL command
) {
    return DIMDeviceProduct;
}

static NSString *DIMHookSystemVersion(
    id self,
    SEL command
) {
    return DIMSystemVersion;
}

static BOOL DIMClassOwnsSelector(
    Class cls,
    SEL selector
) {
    unsigned int methodCount = 0;

    Method *methods = class_copyMethodList(
        cls,
        &methodCount
    );

    BOOL found = NO;

    for (unsigned int i = 0; i < methodCount; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }

    free(methods);

    return found;
}

static void DIMSwizzleInstanceMethod(
    Class cls,
    SEL selector,
    IMP replacement
) {
    if (!cls || !selector || !replacement) {
        return;
    }

    Method method = class_getInstanceMethod(
        cls,
        selector
    );

    if (!method) {
        return;
    }

    IMP current = method_getImplementation(method);

    if (current == replacement) {
        return;
    }

    const char *types = method_getTypeEncoding(method);

    if (DIMClassOwnsSelector(cls, selector)) {
        method_setImplementation(
            method,
            replacement
        );
    } else {
        BOOL added = class_addMethod(
            cls,
            selector,
            replacement,
            types
        );

        if (!added) {
            method_setImplementation(
                method,
                replacement
            );
        }
    }
}

static void DIMInstallUIDeviceHooks(void) {
    Class deviceClass = [UIDevice class];

    DIMSwizzleInstanceMethod(
        deviceClass,
        @selector(model),
        (IMP)DIMHookDeviceModel
    );

    DIMSwizzleInstanceMethod(
        deviceClass,
        @selector(localizedModel),
        (IMP)DIMHookLocalizedModel
    );

    DIMSwizzleInstanceMethod(
        deviceClass,
        @selector(systemVersion),
        (IMP)DIMHookSystemVersion
    );
}

// ============================================================
// INSTALL ALL FISHHOOK REBINDINGS
// ============================================================

static void DIMInstallFishhook(void) {
    struct DIMRebinding rebindings[] = {
        {
            "sysctl",
            (void *)DIMHookSysctl,
            (void **)&DIMOriginalSysctl
        },
        {
            "sysctlbyname",
            (void *)DIMHookSysctlByName,
            (void **)&DIMOriginalSysctlByName
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
}

// ============================================================
// DIM INITIALIZATION
// ============================================================

__attribute__((constructor))
static void DIMInitialize(void) {
    @autoreleasepool {
        if (!DIMShouldRunInCurrentApplication()) {
            return;
        }

        // Capture real kernel data before installing fishhook.
        DIMCaptureOriginalKernelInformation();

        // Install fishhook rebindings.
        DIMInstallFishhook();

        // Install UIDevice method replacements.
        DIMInstallUIDeviceHooks();
    }
}
