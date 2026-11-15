#!/usr/bin/env python3
# Copyright (c) 2026 Nightscout Foundation.
# Licensed under the MIT License. See LICENSE in the project root.
"""Generate SibionicsKit.xcodeproj/project.pbxproj.

objectVersion 77 / Xcode 16 synchronized folder groups, four targets:
SibionicsKit, SibionicsKitUI, SibionicsKitPlugin, SibionicsKitTests.

LoopKit and LoopKitUI are resolved from BUILT_PRODUCTS_DIR, i.e. this project is
meant to be built inside the Trio workspace (same arrangement as the sibling
kit projects). Run from anywhere:

    python3 Scripts/gen_pbxproj.py SibionicsKit.xcodeproj/project.pbxproj
"""

import itertools
import re
import sys

_counter = itertools.count(1)


def uid():
    return "5741" + format(next(_counter), "020X")


objs = {}


def add(u, body):
    objs[u] = body


def arr(items, indent=5):
    pad = "\t" * indent
    return "".join(f"{pad}{i},\n" for i in items)


# ---- external frameworks from the Trio workspace build products ----
ext_frameworks = {}
for fw in ("LoopKit", "LoopKitUI"):
    u = uid()
    ext_frameworks[fw] = u
    add(
        u,
        f"{u} /* {fw}.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; "
        f"path = {fw}.framework; sourceTree = BUILT_PRODUCTS_DIR; }};",
    )

products = {
    "SibionicsKit": ("SibionicsKit.framework", "wrapper.framework"),
    "SibionicsKitUI": ("SibionicsKitUI.framework", "wrapper.framework"),
    "SibionicsKitPlugin": ("SibionicsKitPlugin.loopplugin", "wrapper.framework"),
    "SibionicsKitTests": ("SibionicsKitTests.xctest", "wrapper.cfbundle"),
}
product_ref = {}
for tgt, (path, ftype) in products.items():
    u = uid()
    product_ref[tgt] = u
    add(
        u,
        f"{u} /* {path} */ = {{isa = PBXFileReference; explicitFileType = {ftype}; includeInIndex = 0; "
        f"path = {path}; sourceTree = BUILT_PRODUCTS_DIR; }};",
    )

sync_group = {folder: uid() for folder in ("SibionicsKit", "SibionicsKitUI", "SibionicsKitPlugin", "SibionicsKitTests")}
plugin_exc = uid()


def sync_group_block(folder, u):
    if folder == "SibionicsKitPlugin":
        return (
            f"{u} /* {folder} */ = {{\n"
            f"\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
            f"\t\t\texceptions = (\n\t\t\t\t{plugin_exc} /* Exceptions for \"{folder}\" folder */,\n\t\t\t);\n"
            f"\t\t\tpath = {folder};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};"
        )
    return (
        f"{u} /* {folder} */ = {{\n"
        f"\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
        f"\t\t\tpath = {folder};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};"
    )


def build_file(ref, label, embed=False):
    u = uid()
    if embed:
        add(
            u,
            f"{u} /* {label} in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {ref} /* {label} */; "
            f"settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};",
        )
    else:
        add(u, f"{u} /* {label} in Frameworks */ = {{isa = PBXBuildFile; fileRef = {ref} /* {label} */; }};")
    return u


link_map = {
    "SibionicsKit": [(ext_frameworks["LoopKit"], "LoopKit.framework")],
    "SibionicsKitUI": [
        (product_ref["SibionicsKit"], "SibionicsKit.framework"),
        (ext_frameworks["LoopKit"], "LoopKit.framework"),
        (ext_frameworks["LoopKitUI"], "LoopKitUI.framework"),
    ],
    "SibionicsKitPlugin": [
        (product_ref["SibionicsKit"], "SibionicsKit.framework"),
        (product_ref["SibionicsKitUI"], "SibionicsKitUI.framework"),
    ],
    "SibionicsKitTests": [(product_ref["SibionicsKit"], "SibionicsKit.framework")],
}
embed_map = {
    "SibionicsKitPlugin": [
        (product_ref["SibionicsKit"], "SibionicsKit.framework"),
        (product_ref["SibionicsKitUI"], "SibionicsKitUI.framework"),
    ],
}

frameworks_phase = {}
for tgt, links in link_map.items():
    bfs = [build_file(ref, label) for ref, label in links]
    u = uid()
    frameworks_phase[tgt] = u
    add(
        u,
        f"{u} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n{arr(bfs)}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};",
    )

embed_phase = {}
for tgt, embeds in embed_map.items():
    bfs = [build_file(ref, label, embed=True) for ref, label in embeds]
    u = uid()
    embed_phase[tgt] = u
    add(
        u,
        f'{u} /* Embed Frameworks */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n'
        f'\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tfiles = (\n{arr(bfs)}\t\t\t);\n'
        f"\t\t\tname = \"Embed Frameworks\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};",
    )

sources_phase, resources_phase, headers_phase = {}, {}, {}
for tgt in products:
    su = uid()
    sources_phase[tgt] = su
    add(
        su,
        f"{su} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};",
    )
    ru = uid()
    resources_phase[tgt] = ru
    add(
        ru,
        f"{ru} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};",
    )
    if tgt != "SibionicsKitTests":
        hu = uid()
        headers_phase[tgt] = hu
        add(
            hu,
            f"{hu} /* Headers */ = {{\n\t\t\tisa = PBXHeadersBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};",
        )

project_uid = uid()
dep_map = {
    "SibionicsKitUI": ["SibionicsKit"],
    "SibionicsKitPlugin": ["SibionicsKit", "SibionicsKitUI"],
    "SibionicsKitTests": ["SibionicsKit"],
}
target_uid = {tgt: uid() for tgt in products}
dependency_refs = {tgt: [] for tgt in products}
for tgt, deps in dep_map.items():
    for dep in deps:
        proxy = uid()
        add(
            proxy,
            f"{proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
            f"\t\t\tcontainerPortal = {project_uid} /* Project object */;\n\t\t\tproxyType = 1;\n"
            f"\t\t\tremoteGlobalIDString = {target_uid[dep]};\n\t\t\tremoteInfo = {dep};\n\t\t}};",
        )
        d = uid()
        add(
            d,
            f"{d} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n"
            f"\t\t\ttarget = {target_uid[dep]} /* {dep} */;\n\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n\t\t}};",
        )
        dependency_refs[tgt].append(d)

COMMON_WARNINGS = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.6;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tVERSIONING_SYSTEM = "apple-generic";
\t\t\t\tVERSION_INFO_PREFIX = "";"""


def project_cfg(name, debug):
    if debug:
        extra = (
            "\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n"
            "\t\t\t\tENABLE_TESTABILITY = YES;\n"
            "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n"
            '\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t);\n'
            "\t\t\t\tONLY_ACTIVE_ARCH = YES;\n"
            '\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";\n'
            '\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";\n'
        )
    else:
        extra = (
            '\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";\n'
            "\t\t\t\tENABLE_NS_ASSERTIONS = NO;\n"
            "\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n"
            "\t\t\t\tVALIDATE_PRODUCT = YES;\n"
        )
    u = uid()
    add(
        u,
        f"{u} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
        f"{COMMON_WARNINGS}\n{extra}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};",
    )
    return u


def target_cfg(name, tgt, debug):
    lines = [
        "\t\t\t\tCODE_SIGN_STYLE = Automatic;",
        "\t\t\t\tCURRENT_PROJECT_VERSION = 1;",
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t\t\"@loader_path/Frameworks\",\n\t\t\t\t);",
        "\t\t\t\tMARKETING_VERSION = 1.0;",
        f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = org.loopkit.{tgt};",
        "\t\t\t\tSWIFT_STRICT_CONCURRENCY = targeted;",
        "\t\t\t\tSWIFT_VERSION = 5.0;",
    ]
    if tgt in ("SibionicsKit", "SibionicsKitUI"):
        lines += [
            "\t\t\t\tDEFINES_MODULE = NO;",
            "\t\t\t\tDYLIB_COMPATIBILITY_VERSION = 1;",
            "\t\t\t\tDYLIB_CURRENT_VERSION = 1;",
            '\t\t\t\tDYLIB_INSTALL_NAME_BASE = "@rpath";',
            "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;",
            '\t\t\t\tINSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";',
            '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME:c99extidentifier)";',
            "\t\t\t\tSKIP_INSTALL = YES;",
            '\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";',
            "\t\t\t\tTARGETED_DEVICE_FAMILY = 1;",
        ]
    elif tgt == "SibionicsKitPlugin":
        lines += [
            "\t\t\t\tDYLIB_COMPATIBILITY_VERSION = 1;",
            "\t\t\t\tDYLIB_CURRENT_VERSION = 1;",
            '\t\t\t\tDYLIB_INSTALL_NAME_BASE = "@rpath";',
            "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;",
            "\t\t\t\tINFOPLIST_FILE = SibionicsKitPlugin/Info.plist;",
            '\t\t\t\tINSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";',
            '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME:c99extidentifier)";',
            "\t\t\t\tSKIP_INSTALL = YES;",
            '\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";',
            "\t\t\t\tTARGETED_DEVICE_FAMILY = 1;",
            "\t\t\t\tWRAPPER_EXTENSION = loopplugin;",
        ]
    else:
        lines += [
            "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;",
            '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";',
            '\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";',
            '\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";',
        ]
    u = uid()
    add(
        u,
        f"{u} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
        + "\n".join(lines)
        + f"\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};",
    )
    return u


def cfg_list(name, debug_u, release_u):
    u = uid()
    add(
        u,
        f"{u} /* {name} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{debug_u} /* Debug */,\n\t\t\t\t{release_u} /* Release */,\n\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};",
    )
    return u


proj_cfg_list = cfg_list(
    'Build configuration list for PBXProject "SibionicsKit"',
    project_cfg("Debug", True),
    project_cfg("Release", False),
)

target_cfg_list = {}
for tgt in products:
    target_cfg_list[tgt] = cfg_list(
        f'Build configuration list for PBXNativeTarget "{tgt}"',
        target_cfg("Debug", tgt, True),
        target_cfg("Release", tgt, False),
    )

for tgt in products:
    phases = []
    if tgt in headers_phase:
        phases.append(f"{headers_phase[tgt]} /* Headers */")
    phases.append(f"{sources_phase[tgt]} /* Sources */")
    phases.append(f"{frameworks_phase[tgt]} /* Frameworks */")
    phases.append(f"{resources_phase[tgt]} /* Resources */")
    if tgt in embed_phase:
        phases.append(f"{embed_phase[tgt]} /* Embed Frameworks */")
    deps = dependency_refs[tgt]
    ptype = (
        "com.apple.product-type.bundle.unit-test"
        if tgt == "SibionicsKitTests"
        else "com.apple.product-type.framework"
    )
    body = (
        f"{target_uid[tgt]} /* {tgt} */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f'\t\t\tbuildConfigurationList = {target_cfg_list[tgt]} /* Build configuration list for PBXNativeTarget "{tgt}" */;\n'
        f"\t\t\tbuildPhases = (\n" + arr(phases) + "\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n" + arr([f"{d} /* PBXTargetDependency */" for d in deps]) + "\t\t\t);\n"
        f"\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{sync_group[tgt]} /* {tgt} */,\n\t\t\t);\n"
        f"\t\t\tname = {tgt};\n"
        f"\t\t\tpackageProductDependencies = (\n\t\t\t);\n"
        f"\t\t\tproductName = {tgt};\n"
        f"\t\t\tproductReference = {product_ref[tgt]} /* {products[tgt][0]} */;\n"
        f'\t\t\tproductType = "{ptype}";\n'
        f"\t\t}};"
    )
    add(target_uid[tgt], body)

frameworks_group = uid()
add(
    frameworks_group,
    f"{frameworks_group} /* Frameworks */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
    + arr([f"{ext_frameworks[f]} /* {f}.framework */" for f in ("LoopKit", "LoopKitUI")])
    + '\t\t\t);\n\t\t\tname = Frameworks;\n\t\t\tsourceTree = "<group>";\n\t\t}};',
)

products_group = uid()
add(
    products_group,
    f"{products_group} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
    + arr([f"{product_ref[t]} /* {products[t][0]} */" for t in products])
    + '\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};',
)

main_group = uid()
main_children = [f"{sync_group[f]} /* {f} */" for f in ("SibionicsKit", "SibionicsKitUI", "SibionicsKitPlugin", "SibionicsKitTests")]
main_children += [f"{frameworks_group} /* Frameworks */", f"{products_group} /* Products */"]
add(
    main_group,
    f"{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
    + arr(main_children)
    + '\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};',
)

for folder, u in sync_group.items():
    add(u, sync_group_block(folder, u))

add(
    plugin_exc,
    f'{plugin_exc} /* Exceptions for "SibionicsKitPlugin" folder */ = {{\n'
    f"\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
    f"\t\t\tmembershipExceptions = (\n\t\t\t\tInfo.plist,\n\t\t\t);\n"
    f'\t\t\ttarget = {target_uid["SibionicsKitPlugin"]} /* SibionicsKitPlugin */;\n\t\t}};',
)

targets_order = ["SibionicsKit", "SibionicsKitUI", "SibionicsKitPlugin", "SibionicsKitTests"]
add(
    project_uid,
    f"{project_uid} /* Project object */ = {{\n"
    f"\t\t\tisa = PBXProject;\n"
    f"\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
    f"\t\t\t\tLastSwiftUpdateCheck = 2600;\n\t\t\t\tLastUpgradeCheck = 2600;\n\t\t\t}};\n"
    f'\t\t\tbuildConfigurationList = {proj_cfg_list} /* Build configuration list for PBXProject "SibionicsKit" */;\n'
    f"\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
    f"\t\t\tmainGroup = {main_group};\n"
    f"\t\t\tminimizedProjectReferenceProxies = 1;\n"
    f"\t\t\tpreferredProjectObjectVersion = 77;\n"
    f"\t\t\tproductRefGroup = {products_group} /* Products */;\n"
    f'\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n'
    f"\t\t\ttargets = (\n" + arr([f"{target_uid[t]} /* {t} */" for t in targets_order]) + "\t\t\t);\n\t\t}};",
)

out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 77;", "\tobjects = {", ""]
for u in sorted(objs):
    out.append("\t\t" + objs[u])
out.append("\t};")
out.append(f"\trootObject = {project_uid} /* Project object */;")
out.append("}")
text = "\n".join(out) + "\n"
text = text.replace("}};", "};")

defined = set(objs)
referenced = set(re.findall(r"\b(5741[0-9A-F]{20})\b", text))
missing = referenced - defined
if missing:
    print("MISSING uids:", missing)
    sys.exit(1)
if text.count("{") != text.count("}") or text.count("(") != text.count(")"):
    print("unbalanced braces/parens")
    sys.exit(1)

with open(sys.argv[1], "w") as handle:
    handle.write(text)
print(f"wrote {sys.argv[1]}: {len(objs)} objects, {len(referenced)} referenced uids")
