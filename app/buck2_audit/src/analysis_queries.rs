/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under both the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree and the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree.
 */

use std::io::Write;

use async_trait::async_trait;
use buck2_build_api::analysis::calculation::resolve_queries;
use buck2_build_api::calculation::Calculation;
use buck2_cli_proto::ClientContext;
use buck2_common::dice::cells::HasCellResolver;
use buck2_common::dice::file_ops::HasFileOps;
use buck2_common::pattern::resolve::resolve_target_patterns;
use buck2_core::pattern::pattern_type::TargetPatternExtra;
use buck2_core::target::label::TargetLabel;
use buck2_server_ctx::ctx::ServerCommandContextTrait;
use buck2_server_ctx::ctx::ServerCommandDiceContext;
use buck2_server_ctx::partial_result_dispatcher::PartialResultDispatcher;
use buck2_server_ctx::pattern::parse_patterns_from_cli_args;
use buck2_server_ctx::pattern::target_platform_from_client_context;
use dupe::Dupe;
use gazebo::prelude::*;

use crate::AuditCommandCommonOptions;
use crate::AuditSubcommand;

#[derive(Debug, clap::Parser, serde::Serialize, serde::Deserialize)]
#[clap(
    name = "audit-analysis-queries",
    about = "buck audit analysis resolving query attrs"
)]
pub struct AuditAnalysisQueriesCommand {
    #[clap(flatten)]
    common_opts: AuditCommandCommonOptions,

    #[clap(
        name = "TARGET_PATTERNS",
        help = "Patterns to evaluate. The query attributes for targets matching these patterns will be evaluated"
    )]
    patterns: Vec<String>,

    #[clap(
        long,
        help = "Enable to print the outputs for the targets in the resolved queries"
    )]
    include_outputs: bool,
}

#[async_trait]
impl AuditSubcommand for AuditAnalysisQueriesCommand {
    async fn server_execute(
        &self,
        server_ctx: Box<dyn ServerCommandContextTrait>,
        mut stdout: PartialResultDispatcher<buck2_cli_proto::StdoutBytes>,
        client_ctx: ClientContext,
    ) -> anyhow::Result<()> {
        server_ctx
            .with_dice_ctx(async move |server_ctx, ctx| {
                let cells = ctx.get_cell_resolver().await?;

                let global_target_platform =
                    target_platform_from_client_context(&client_ctx, server_ctx, &ctx).await?;

                let parsed_patterns = parse_patterns_from_cli_args::<TargetPatternExtra>(
                    &ctx,
                    &self
                        .patterns
                        .map(|pat| buck2_data::TargetPattern { value: pat.clone() }),
                    server_ctx.working_dir(),
                )
                .await?;
                let resolved_pattern =
                    resolve_target_patterns(&cells, &parsed_patterns, &ctx.file_ops()).await?;

                let mut stdout = stdout.as_writer();

                for (package, spec) in resolved_pattern.specs {
                    match spec {
                        buck2_core::pattern::PackageSpec::Targets(targets) => {
                            for (target, TargetPatternExtra) in targets {
                                let label = TargetLabel::new(package.dupe(), target.as_ref());
                                let configured_target = ctx
                                    .get_configured_target(&label, global_target_platform.as_ref())
                                    .await?;
                                let node =
                                    ctx.get_configured_target_node(&configured_target).await?;
                                let node = node.require_compatible()?;
                                let query_results = resolve_queries(&ctx, &node).await?;
                                writeln!(stdout, "{}:", label)?;
                                for (query, result) in &query_results {
                                    writeln!(stdout, "  {}", query)?;
                                    for (target, providers) in &**result {
                                        writeln!(stdout, "    {}", target.unconfigured())?;
                                        if self.include_outputs {
                                            let outputs = providers
                                                .provider_collection()
                                                .default_info()
                                                .default_outputs_raw();
                                            writeln!(stdout, "        {}", outputs)?;
                                        }
                                    }
                                }
                            }
                        }
                        buck2_core::pattern::PackageSpec::All => {
                            unimplemented!()
                        }
                    }
                }

                Ok(())
            })
            .await
    }

    fn common_opts(&self) -> &AuditCommandCommonOptions {
        &self.common_opts
    }
}
