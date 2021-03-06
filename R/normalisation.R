# lsei import is for scran
#' State-of-the-art preprocessing and normalisation from https://f1000research.com/articles/5-2122/v2 and https://www.bioconductor.org/help/workflows/simpleSingleCell/
#' @param counts The counts matrix, with genes in columns
#' @param has_spike Does this contain spike-ins, for which the gene names are preseded by ERCC
#' @param verbose Whether to add plots
#' @param nmads Number of median deviations for filtering outlier cells
#' @param expressed_in_n_cells Percentage of minimal number of cells a gene has to be expressed
#' @param min_ave_expression Minimal average expression of a gene
#' @param filter_hvg Whether to filter out highly variable genes
#' @param hvg_fdr FDR gene filtering cutoff
#' @param hvg_bio Biological gene filtering cutoff
#' @param min_variable_fraction Minimal number of variable genes to retain
#'
#' @importFrom scater newSCESet calculateQCMetrics isOutlier normalise plotExplanatoryVariables plotExpression plotPCA plotQC nexprs
#' @importFrom SingleCellExperiment isSpike SingleCellExperiment
#' @importFrom BiocGenerics counts sizeFactors
#' @importFrom Biobase pData
#' @importFrom scran computeSumFactors computeSpikeFactors trendVar decomposeVar
#' @importFrom grDevices recordPlot graphics.off
#' @importFrom limSolve lsei
#' @importFrom stats sd
#' @importFrom aroma.light aroma.light
#'
#' @export
normalise_filter_counts <- function(
  counts,
  has_spike = any(grepl("^ERCC", colnames(counts))),
  verbose = FALSE,
  nmads = 3,
  expressed_in_n_cells = 0.05,
  min_ave_expression = 0.05,
  filter_hvg = TRUE,
  hvg_fdr = 0.05,
  hvg_bio = 0.5,
  min_variable_fraction = 0.1
) {
  if (verbose) {
    requireNamespace("grDevices")
    requireNamespace("ggplot2")
    requireNamespace("graphics")
  }


  normalisation_plots <- list()

  ########################################
  # Create data object
  ########################################

  counts <- round(counts)

  sce <- SingleCellExperiment::SingleCellExperiment(list(counts=t(counts)))

  mitochondrial <- grepl("^(mt|MT|mt)-", rownames(sce))
  has_mito <- any(mitochondrial)
  feature_controls <- list()
  if (has_mito) feature_controls$Mt <- mitochondrial
  if (has_spike) feature_controls$ERCC <- grepl("^ERCC", rownames(sce))

  sce <- scater::calculateQCMetrics(sce, feature_controls = feature_controls)

  if (has_spike) {
    is_spike <- grepl("^ERCC", rownames(sce))
    SingleCellExperiment::isSpike(sce, "ERCC") <- is_spike
    summary(is_spike)
  }

  if (verbose) {
    graphics::par(mfrow=c(1,2))
    graphics::hist(sce$total_counts/1e6, xlab="Library sizes (millions)", main="",
                   breaks=20, col="grey80", ylab="Number of cells")
    graphics::hist(sce$total_features, xlab="Number of expressed genes", main="",
                   breaks=20, col="grey80", ylab="Number of cells")
    graphics::par(mfrow=c(1, 1))
    normalisation_plots$library <- grDevices::recordPlot()
  }

  if (verbose) {
    graphics::par(mfrow=c(2,2), mar=c(5.1, 4.1, 0.1, 0.1))
    graphics::hist(sce$total_counts/1e6, xlab="Library sizes (millions)", main="",
                   breaks=20, col="grey80", ylab="Number of cells")
    graphics::hist(sce$total_features, xlab="Number of expressed genes", main="",
                   breaks=20, col="grey80", ylab="Number of cells")
    if (has_spike) graphics::hist(sce$pct_counts_ERCC, xlab="ERCC proportion (%)",
                                  ylab="Number of cells", breaks=20, main="", col="grey80")
    if (has_mito) graphics::hist(sce$pct_counts_Mt, xlab="Mitochondrial proportion (%)",
                                 ylab="Number of cells", breaks=20, main="", col="grey80")
    graphics::par(mfrow=c(1, 1))
    normalisation_plots$cell_quality <- grDevices::recordPlot()

    print(glue::glue("Original: Genes - {dim(sce)[[1]]} Cells - {dim(sce)[[2]]}"))
  }

  ########################################
  # Filter cells
  ########################################
  mito_drop <- rep(FALSE, length(sce$total_counts))
  spike_drop <- rep(FALSE, length(sce$total_counts))

  libsize_drop <- scater::isOutlier(sce$total_counts, nmads=nmads, type="lower", log=TRUE)
  feature_drop <- scater::isOutlier(sce$total_features, nmads=nmads, type="lower", log=TRUE)
  if (has_mito) mito_drop <- scater::isOutlier(sce$pct_counts_Mt, nmads=nmads, type="higher")
  if (has_spike) spike_drop <- scater::isOutlier(sce$pct_counts_ERCC, nmads=nmads, type="higher")

  if (verbose) {
    tibble(sum(mito_drop), sum(spike_drop), sum(libsize_drop), sum(feature_drop)) %>% print()
  }

  sce_cell_filtered <- sce[,!(libsize_drop | feature_drop | mito_drop | spike_drop)]

  if (verbose) {
    print(glue::glue("Cell filter: Genes - {dim(sce_cell_filtered)[[1]]} Cells - {dim(sce_cell_filtered)[[2]]}"))
  }

  ########################################
  # Filter genes
  ########################################

  ave_counts <- rowMeans(BiocGenerics::counts(sce_cell_filtered))
  keep <- ave_counts >= min_ave_expression

  if (verbose) {
    fontsize <- ggplot2::theme(
      axis.text = ggplot2::element_text(size=12),
      axis.title = ggplot2::element_text(size=16)
    )

    graphics::hist(log10(ave_counts), breaks=100, main="", col="grey80",
                   xlab=expression(Log[10]~"average count"))
    graphics::abline(v=log10(min_ave_expression), col="blue", lwd=2, lty=2)
    normalisation_plots$initial_gene_filter <- grDevices::recordPlot()

    print(scater::plotQC(sce_cell_filtered, type = "highest-expression", n=50) + fontsize)
    normalisation_plots$top_genes_qc <- grDevices::recordPlot()
  }

  numcells <- scater::nexprs(sce_cell_filtered, byrow=TRUE)
  alt_keep <- numcells >= ncol(sce_cell_filtered) * expressed_in_n_cells

  if (verbose) {
    graphics::smoothScatter(log10(ave_counts), numcells, xlab=expression(Log[10]~"average count"), ylab="Number of expressing cells")
    if (has_spike) {
      is_ercc <- SingleCellExperiment::isSpike(sce_cell_filtered, type="ERCC")
      graphics::points(log10(ave_counts[is_ercc]), numcells[is_ercc], col="red", pch=16, cex=0.5)
    }

    normalisation_plots$cell_filtering <- grDevices::recordPlot()
  }

  sce_cellgene_filtered <- sce_cell_filtered[keep,]

  if (verbose)print(glue::glue("Gene filter: Genes - {dim(sce_cellgene_filtered)[[1]]} Cells - {dim(sce_cellgene_filtered)[[2]]}"))

  ########################################
  # Normalise
  ########################################

  if (ncol(sce_cellgene_filtered) >= 100) {
    sizes <- c(20, 40, 60, 80)
  } else {
    sizes <- ncol(sce_cellgene_filtered)
  }

  sce_cellgene_filtered <- scran::computeSumFactors(sce_cellgene_filtered, sizes=sizes, positive=TRUE)
  sce_cellgene_filtered <- sce_cellgene_filtered[, sizeFactors(sce_cellgene_filtered) > 0] # as mentioned in the scran documentation, ensure that size factors are higher than 0

  if (verbose) {
    graphics::plot(sizeFactors(sce_cellgene_filtered), sce_cellgene_filtered$total_counts/1e6, log="xy",
                   ylab="Library size (millions)", xlab="Size factor")
    normalisation_plots$size_factor <- grDevices::recordPlot()
  }

  if(has_spike) {
    sce_cellgene_filtered <- scran::computeSpikeFactors(sce_cellgene_filtered, type="ERCC", general.use=FALSE)
    if(any(is.na(sizeFactors(sce_cellgene_filtered, type="ERCC")))) {
      warning("Some cells do not have any spike-ins, this will cause an error further away. Remove spike-ins.")
    }
  }

  sce_normalised <- scater::normalise(sce_cellgene_filtered)

  if (verbose)print(glue::glue("normalised: Genes - {dim(sce_normalised)[[1]]} Cells - {dim(sce_normalised)[[2]]}"))

  ########################################
  # Select highly variable genes
  ########################################

  if (filter_hvg) {
    if (verbose) {
      if(has_spike) {
        normalisation_plots$ercc <-
          scater::plotExplanatoryVariables(sce_normalised, variables=c("total_counts_ERCC", "log10_total_counts_ERCC")) +
          fontsize
      }
    }

    var_fit <- scran::trendVar(sce_normalised, method="spline", use.spikes=has_spike) # requires aroma.light
    var_out <- scran::decomposeVar(sce_normalised, var_fit)

    if (verbose) {
      graphics::plot(var_out$mean, var_out$total, pch=16, cex=0.6, xlab="Mean log-expression",
                     ylab="Variance of log-expression")
      o <- order(var_out$mean)
      graphics::lines(var_out$mean[o], var_out$tech[o], col="dodgerblue", lwd=2)

      if (has_spike) {
        cur_spike <- SingleCellExperiment::isSpike(sce)
        graphics::points(var_out$mean[cur_spike], var_out$total[cur_spike], col="red", pch=16)
      }

      normalisation_plots$gene_variance <- grDevices::recordPlot()

      normalisation_plots$gene_selection <- var_out %>%
        ggplot2::ggplot() +
        ggplot2::geom_point(ggplot2::aes_string("FDR", "bio")) +
        ggplot2::geom_hline(yintercept = hvg_bio) +
        ggplot2::geom_vline(xintercept = hvg_fdr)
    }

    var_out <- var_out[order(var_out$bio, decreasing=TRUE),]
    hvg_out <- var_out[which(var_out$FDR <= hvg_fdr & var_out$bio >= hvg_bio),]
    if(nrow(hvg_out) < min_variable_fraction * nrow(var_out)) {
      hvg_out <- var_out[seq(1, ceiling(min_variable_fraction * nrow(var_out))), ]
    }

    if (verbose & nrow(hvg_out) >= 10) {
      normalisation_plots$top_genes <- scater::plotExpression(sce_normalised, rownames(hvg_out)[1:10]) + fontsize
      normalisation_plots$bottom_genes <- scater::plotExpression(sce_normalised, rownames(hvg_out)[(nrow(hvg_out)-10):nrow(hvg_out)]) + fontsize
    }
    sce_normalised_filtered <- sce_normalised[rownames(hvg_out),]

    if (verbose) print(glue::glue("Variable genes filtered: Genes - {dim(sce_normalised_filtered)[[1]]} Cells - {dim(sce_normalised_filtered)[[2]]}"))
  } else {
    sce_normalised_filtered <- sce_normalised
  }

  expression_normalised_filtered <- Biobase::exprs(sce_normalised_filtered) %>% t()
  counts_filtered <- counts[rownames(expression_normalised_filtered),colnames(expression_normalised_filtered)]

  ########################################
  # Final filter on variability
  ########################################
  repeat {
    gene_sds <- counts_filtered %>% apply(2, stats::sd)
    cell_sds <- counts_filtered %>% apply(1, stats::sd)

    genes_filtered <- which(gene_sds > 0, useNames=TRUE)
    cells_filtered <- which(cell_sds > 0, useNames=TRUE)
    expression_normalised_filtered <- expression_normalised_filtered[cells_filtered, genes_filtered]
    counts_filtered <- counts_filtered[cells_filtered, genes_filtered]

    if((min(c(gene_sds, 1), na.rm=TRUE) > 0) && (min(c(cell_sds, 1), na.rm=TRUE) > 0)){
      break
    }
  }

  ########################################
  # Output
  ########################################

  if(verbose) {
    type <- NULL # satisfy r cmd check

    normalisation_steps <-tribble(
      ~type, ~ngenes, ~ncells,
      "original", dim(sce)[1], dim(sce)[2],
      "cell_quality_filtering", dim(sce_cell_filtered)[1], dim(sce_cell_filtered)[2],
      "gene_expression_filtering", dim(sce_cellgene_filtered)[1], dim(sce_cellgene_filtered)[2],
      "normalisation", dim(sce_normalised)[1], dim(sce_normalised)[2],
      "gene_variability_filtering", dim(sce_normalised_filtered)[1], dim(sce_normalised_filtered)[2],
      "final_filtering", dim(expression_normalised_filtered)[2], dim(expression_normalised_filtered)[1]
    )
    normalisation_plots$n_retained <- normalisation_steps %>%
      mutate(type = factor(type, levels=rev(type))) %>%
      gather("dimension", "n", -type) %>%
      ggplot2::ggplot() +
      ggplot2::geom_bar(ggplot2::aes_string("type", "n", fill = "dimension"), position = "dodge", stat = "identity") +
      ggplot2::facet_wrap(~dimension, scales = "free_x") +
      ggplot2::coord_flip()
  } else {
    normalisation_steps <- NULL
  }

  lst(
    expression = expression_normalised_filtered,
    counts = counts_filtered,
    normalisation_plots,
    info = lst(
      has_spike,
      has_mito,
      normalisation_steps
    )
  )
}
