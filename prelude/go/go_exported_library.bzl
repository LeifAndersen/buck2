# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load("@prelude//cxx:linker.bzl", "get_default_shared_library_name")
load(
    "@prelude//linking:link_groups.bzl",
    "merge_link_group_lib_info",
)
load(
    "@prelude//linking:link_info.bzl",
    "Archive",
    "ArchiveLinkable",
    "LibOutputStyle",
    "LinkInfo",
    "LinkInfos",
    "LinkStyle",
    "LinkedObject",
    "MergedLinkInfo",  # @unused Used as a type
    "SharedLibLinkable",
    "create_merged_link_info",
)
load(
    "@prelude//linking:linkable_graph.bzl",
    "create_linkable_graph",
    "create_linkable_graph_node",
    "create_linkable_node",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibraries",
    "SharedLibraryInfo",
    "create_shlib",
    "merge_shared_libraries",
)
load(
    "@prelude//utils:utils.bzl",
    "map_idx",
    "map_val",
    "value_or",
)
load(":link.bzl", "GoBuildMode", "link")
load(":package_builder.bzl", "build_package")

def go_exported_library_impl(ctx: AnalysisContext) -> list[Provider]:
    lib, pkg_info = build_package(
        ctx,
        "main",
        ctx.attrs.srcs,
        package_root = ctx.attrs.package_root,
        deps = ctx.attrs.deps,
        compiler_flags = ctx.attrs.compiler_flags,
        race = ctx.attrs._race,
        asan = ctx.attrs._asan,
        embedcfg = ctx.attrs.embedcfg,
        # We need to set CGO_DESABLED for "pure" Go libraries, otherwise CGo files may be selected for compilation.
        force_disable_cgo = True,
    )

    def link_variant(build_mode: GoBuildMode):
        (exp_lib, _, _) = link(
            ctx,
            lib,
            deps = ctx.attrs.deps,
            build_mode = build_mode,
            link_style = value_or(map_val(LinkStyle, ctx.attrs.link_style), LinkStyle("static_pic")),
            linker_flags = ctx.attrs.linker_flags,
            external_linker_flags = ctx.attrs.external_linker_flags,
            race = ctx.attrs._race,
            asan = ctx.attrs._asan,
        )
        return exp_lib

    c_archive = link_variant(GoBuildMode("c_archive"))  # .a - PIC-arcive
    c_shared = link_variant(GoBuildMode("c_shared"))  # .so - PIC-shared_lib

    cxx_toolchain = ctx.attrs._cxx_toolchain[CxxToolchainInfo]

    soname = get_default_shared_library_name(cxx_toolchain.linker_info, ctx.label)

    link_infos = {
        LibOutputStyle("archive"): LinkInfos(
            default = LinkInfo(linkables = [ArchiveLinkable(
                archive = Archive(artifact = c_archive),
                linker_type = cxx_toolchain.linker_info.type,
            )]),
        ),
        LibOutputStyle("pic_archive"): LinkInfos(
            default = LinkInfo(linkables = [ArchiveLinkable(
                archive = Archive(artifact = c_archive),
                linker_type = cxx_toolchain.linker_info.type,
            )]),
        ),
        LibOutputStyle("shared_lib"): LinkInfos(
            default = LinkInfo(linkables = [SharedLibLinkable(
                lib = c_shared,
            )]),
        ),
    }

    shared_libs = SharedLibraries(libraries = [
        create_shlib(
            soname = soname,
            label = ctx.label,
            lib = LinkedObject(
                output = c_shared,
                unstripped_output = c_shared,
            ),
        ),
    ])

    return [
        DefaultInfo(
            default_output = c_archive if ctx.attrs.build_mode == "c_archive" else c_shared,
        ),
        create_merged_link_info(
            ctx,
            cxx_toolchain.pic_behavior,
            link_infos = link_infos,
            deps = filter(None, map_idx(MergedLinkInfo, ctx.attrs.deps)),
        ),
        merge_shared_libraries(
            ctx.actions,
            node = shared_libs,
            deps = filter(None, map_idx(SharedLibraryInfo, ctx.attrs.deps)),
        ),
        merge_link_group_lib_info(deps = ctx.attrs.deps),
        create_linkable_graph(
            ctx,
            node = create_linkable_graph_node(
                ctx,
                linkable_node = create_linkable_node(
                    ctx,
                    default_soname = soname,
                    deps = ctx.attrs.deps,
                    link_infos = link_infos,
                    shared_libs = shared_libs,
                ),
            ),
            deps = ctx.attrs.deps,
        ),
        pkg_info,
    ]
