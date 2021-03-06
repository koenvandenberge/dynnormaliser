#' Extract the prior information from the milestone network
#'
#' For example, what are the start cells, the end cells, to which milestone does each cell belong to.
#'
#' @param milestone_ids The milestone ids
#' @param milestone_network The milestone network
#' @param progressions The progressions
#' @param milestone_percentages The milestone percentages
#' @param counts The counts matrix
#' @param feature_info The feature info
#' @param cell_info The cell info
#'
#' @importFrom Seurat CreateSeuratObject FindAllMarkers
#' @export
generate_prior_information <- function(
  milestone_ids,
  milestone_network,
  progressions,
  milestone_percentages,
  counts,
  feature_info,
  cell_info
) {
  # start cells
  # check if there are one or more starting milestones
  start_milestones <- setdiff(milestone_ids, milestone_network$to)
  if (length(start_milestones) > 0) {
    start_cells <- progressions %>%
      filter(from %in% start_milestones) %>%
      group_by(from) %>%
      filter(percentage == min(percentage)) %>%
      sample_n(1) %>%
      pull(cell_id) %>%
      unique()
    if (length(start_cells) != length(start_milestones)) {warning("Not every start milestone has a cell")}
  } else {
    start_cells <- unique(progressions$cell_id)
  }

  # end cells
  end_milestones <- setdiff(milestone_ids, milestone_network$from)
  end_cells <- progressions %>%
    filter(to %in% end_milestones) %>%
    group_by(to) %>%
    arrange(percentage) %>%
    filter(percentage == max(percentage)) %>%
    sample_n(1) %>%
    pull(cell_id) %>%
    unique()
  if (length(end_cells) != length(end_milestones)) {warning("Not every end milestone has a cell")}

  # cell grouping
  grouping_assignment <- milestone_percentages %>%
    group_by(cell_id) %>%
    summarise(group_id = milestone_id[which.max(percentage)])
  grouping_network <- milestone_network %>% select(from, to)

  # marker genes
  if ("housekeeping" %in% colnames(feature_info)) {
    marker_feature_ids <- feature_info %>%
      filter(!housekeeping) %>%
      pull(feature_id)
  } else {
    ident <- grouping_assignment %>%
      slice(match(rownames(counts), cell_id)) %>%
      pull(group_id) %>%
      factor() %>%
      setNames(rownames(counts))

    seurat <- Seurat::CreateSeuratObject(t(counts[names(ident), ]))

    seurat@ident <- ident

    old_warn <- getOption("warn")
    options(warn = 2)
    changing <- Seurat::FindAllMarkers(seurat, logfc.treshold = 1, min.pct = 0.4)
    options(warn = old_warn)

    marker_feature_ids <- changing %>%
      filter(abs(avg_logFC) >= 1) %>%
      .$gene %>%
      unique()
  }

  # number of branches
  n_branches <- nrow(milestone_network)

  # number of end states
  n_end_states <- length(end_milestones)

  # time information
  time <-
    if ("simulationtime" %in% colnames(cell_info)) {
      setNames(cell_info$simulationtime, cell_info$cell_id)
    } else {
      NULL
    }

  timecourse <-
    if ("timepoint" %in% colnames(cell_info)) {
      setNames(cell_info$timepoint, cell_info$cell_id)
    } else {
      NULL
    }

  # return output
  lst(
    start_milestones,
    start_cells,
    end_milestones,
    end_cells,
    grouping_assignment,
    grouping_network,
    marker_feature_ids,
    n_branches,
    time,
    timecourse,
    n_end_states
  )
}
