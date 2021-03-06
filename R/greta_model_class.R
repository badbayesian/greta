# greta_model objects

#' @name model
#' @title greta model objects
#' @description Create a \code{greta_model} object representing a statistical
#'   model (using \code{model}), and plot a graphical representation of the
#'   model. Statistical inference can be performed on \code{greta_model} objects
#'   with \code{\link{mcmc}}
NULL

#' @rdname model
#' @export
#' @importFrom parallel detectCores
#'
#' @param \dots for \code{model}: \code{greta_array} objects to be tracked by
#'   the model (i.e. those for which samples will be retained during mcmc). If
#'   not provided, all of the non-data \code{greta_array} objects defined in the
#'   calling environment will be tracked. For \code{print} and
#'   \code{plot}:further arguments passed to or from other methods (currently
#'   ignored).
#'
#' @param precision the floating point precision to use when evaluating this
#'   model. Switching from \code{'single'} (the default) to \code{'double'}
#'   should reduce the risk of numerical instability during sampling, but will
#'   also increase the computation time, particularly for large models.
#'
#' @param n_cores the number of cpu cores to use when evaluating this model.
#'   Defaults to and cannot exceed the number detected by
#'   \code{parallel::detectCores}.
#'
#' @param compile whether to apply
#'   \href{https://www.tensorflow.org/performance/xla/}{XLA JIT compilation} to
#'   the tensorflow graph representing the model. This may slow down model
#'   definition, and speed up model evaluation.
#'
#' @details \code{model()} takes greta arrays as arguments, and defines a
#'   statistical model by finding all of the other greta arrays on which they
#'   depend, or which depend on them. Further arguments to \code{model} can be used to configure the tensorflow
#'   graph representing the model, to tweak performance.
#'
#' @return \code{model} - a \code{greta_model} object.
#'
#' @examples
#'
#' \dontrun{
#'
#' # define a simple model
#' mu = variable()
#' sigma = lognormal(1, 0.1)
#' x = rnorm(10)
#' distribution(x) = normal(mu, sigma)
#'
#' m <- model(mu, sigma)
#'
#' plot(m)
#' }
#'
model <- function (...,
                   precision = c('single', 'double'),
                   n_cores = NULL,
                   compile = TRUE) {

  check_tf_version('error')

  # get the floating point precision
  tf_float <- switch(match.arg(precision),
                     single = tf$float32,
                     double = tf$float64)

  # check and set the number of cores
  n_detected <- parallel::detectCores()
  if (is.null(n_cores)) {
    n_cores <- n_detected
  } else {

    n_cores <- as.integer(n_cores)

    if (!n_cores %in% seq_len(n_detected)) {
      warning (n_cores, ' cores were requested, but only ',
               n_detected, ' cores are available. Using ',
               n_detected, ' cores.')
      n_cores <- n_detected
    }
  }

  # flush all tensors from the default graph
  tf$reset_default_graph()

  # nodes required
  target_greta_arrays <- list(...)

  # if no arrays were specified, find all of the non-data arrays
  if (identical(target_greta_arrays, list())) {

    target_greta_arrays <- all_greta_arrays(parent.frame(),
                                            include_data = FALSE)

  } else {

    # otherwise, find variable names for the provided nodes
    names <- substitute(list(...))[-1]
    names <- vapply(names, deparse, '')
    names(target_greta_arrays) <- names

  }

  if (length(target_greta_arrays) == 0) {
    stop ('could not find any non-data greta arrays',
          call. = FALSE)
  }

  # get the dag containing the target nodes
  dag <- dag_class$new(target_greta_arrays,
                       tf_float = tf_float,
                       n_cores = n_cores,
                       compile = compile)

  # get and check the types
  types <- dag$node_types

  # the user might pass greta arrays with groups of nodes that are unconnected
  # to one another. Need to check there are densities in each graph

  # so find the subgraph to which each node belongs
  graph_id <- dag$subgraph_membership()

  graphs <- unique(graph_id)
  n_graphs <- length(graphs)

  # separate messages to avoid the subgraphs issue for beginners
  if (n_graphs == 1) {
    density_message <- paste('none of the greta arrays in the model are',
                             'associated with a probability density, so a',
                             'model cannot be defined')
    variable_message <- paste('none of the greta arrays in the model are',
                              'unknown, so a model cannot be defined')
  } else {
    density_message <- paste('the model contains', n_graphs, 'disjoint graphs,',
                             'one or more of these sub-graphs does not contain',
                             'any greta arrays that are associated with a',
                             'probability density, so a model cannot be',
                             'defined')
    variable_message <- paste('the model contains', n_graphs, 'disjoint',
                              'graphs, one or more of these sub-graphs does',
                              'not contain any greta arrays that are unknown,',
                              'so a model cannot be defined')
  }

  for (graph in graphs) {

    types_sub <- types[graph_id == graph]

    # check they have a density among them
    if (!('distribution' %in% types_sub))
      stop (density_message, call. = FALSE)

    # check they have a variable node among them
    if (!('variable' %in% types_sub))
      stop (variable_message, call. = FALSE)

  }

  # define the TF graph
  dag$define_tf()

  # create the model object and add details
  model <- as.greta_model(dag)
  model$target_greta_arrays <- target_greta_arrays
  model$visible_greta_arrays <- all_greta_arrays(parent.frame())

  model

}

# register generic method to coerce objects to a greta model
as.greta_model <- function(x, ...)
  UseMethod('as.greta_model', x)

as.greta_model.dag_class <- function (x, ...) {
  ans <- list(dag = x)
  class(ans) <- 'greta_model'
  ans
}

#' @rdname model
#' @param x a \code{greta_model} object
#' @export
print.greta_model <- function (x, ...) {
  cat('greta model')
}

#' @rdname model
#' @param y unused default argument
#'
#' @details The plot method produces a visual representation of the defined
#'   model. It uses the \code{DiagrammeR} package, which must be installed
#'   first. Here's a key to the plots:
#'   \if{html}{\figure{plotlegend.png}{options: width="100\%"}}
#'   \if{latex}{\figure{plotlegend.pdf}{options: width=7cm}}
#'
#' @return \code{plot} - a \code{\link[DiagrammeR:create_graph]{DiagrammeR::gdr_graph}} object (invisibly).
#'
#' @export
plot.greta_model <- function (x, y, ...) {

  if (!requireNamespace('DiagrammeR', quietly = TRUE))
    stop ('the DiagrammeR package must be installed to plot greta models',
          call. = FALSE)

  # set up graph
  dag_mat <- x$dag$adjacency_matrix()

  gr <- DiagrammeR::from_adj_matrix(dag_mat,
                                    mode = 'directed',
                                    use_diag = FALSE)

  n_nodes <- nrow(gr$nodes_df)
  n_edges <- nrow(gr$edges_df)

  names <- names(x$dag$node_list)
  types <- x$dag$node_types
  to <- gr$edges_df$to
  from <- gr$edges_df$from

  node_shapes <- rep('square', n_nodes)
  node_shapes[types == 'variable'] <- 'circle'
  node_shapes[types == 'distribution'] <- 'diamond'
  node_shapes[types == 'operation'] <- 'circle'

  node_edge_colours <- rep(greta_col('lighter'), n_nodes)
  node_edge_colours[types == 'distribution'] <- greta_col('light')
  node_edge_colours[types == 'operation'] <- 'lightgray'

  node_colours <- rep(greta_col('super_light'), n_nodes)
  node_colours[types == 'distribution'] <- greta_col('lighter')
  node_colours[types == 'operation'] <- 'lightgray'
  node_colours[types == 'data'] <- 'white'

  node_size <- rep(1, length(types))
  node_size[types == 'variable'] <- 0.6
  node_size[types == 'data'] <- 0.5
  node_size[types == 'operation'] <- 0.2

  # get node labels
  node_labels <- vapply(x$dag$node_list, member, 'plotting_label()', FUN.VALUE = '')

  #add greta array names where available
  known_nodes <- vapply(x$visible_greta_arrays, member,
                        'node$unique_name', FUN.VALUE = '')
  known_nodes <- known_nodes[known_nodes %in% names]
  known_idx <- match(known_nodes, names)
  node_labels[known_idx] <- paste(names(known_nodes),
                                  node_labels[known_idx],
                                  sep = '\n')

  # for the operation nodes, add the operation to the edges
  op_idx <- which(types == 'operation')
  op_names <- vapply(x$dag$node_list[op_idx],
                     member,
                     'operation_name',
                     FUN.VALUE = '')
  op_names <- gsub('`', '', op_names)

  ops <- rep('', length(types))
  ops[op_idx] <- op_names

  # get ops as tf operations
  edge_labels <- ops[to]

  # for distributions, put the parameter names on the edges
  distrib_to <- which(types == 'distribution')

  parameter_list <- lapply(x$dag$node_list[distrib_to], member, 'parameters')
  # parameter_names <- lapply(parameter_list, names)
  node_names <- lapply(parameter_list,
                       function (parameters) {
                         vapply(parameters, member, 'unique_name', FUN.VALUE = '')
                       })

  # for each distribution
  for (i in seq_along(node_names)) {

    from_idx <- match(node_names[[i]], names)
    to_idx <- match(names(node_names)[i], names)
    param_names <- names(node_names[[i]])

    # assign them
    for (j in seq_along(from_idx)) {
      idx <- from == from_idx[j] & to == to_idx
      edge_labels[idx] <- param_names[j]
    }

  }

  edge_style <- rep('solid', length(to))

  # put dashed line between target and distribution
  # for distributions, put the parameter names on the edges
  names <- names(x$dag$node_list)
  types <- x$dag$node_types
  distrib_idx <- which(types == 'distribution')

  target_names <- vapply(x$dag$node_list[distrib_idx], member, 'target$unique_name', FUN.VALUE = '')
  distribution_names <- names(target_names)
  distribution_idx <- match(distribution_names, names)
  target_idx <- match(target_names, names)

  # for each distribution
  for (i in seq_along(distribution_idx)) {

    idx <- which(to == target_idx[i] & from == distribution_idx[i])
    edge_style[idx] <- 'dashed'

  }

  # node options
  gr$nodes_df$type <- 'lower'
  gr$nodes_df$fontcolor <- greta_col('dark')
  gr$nodes_df$fontsize <- 12
  gr$nodes_df$penwidth <- 2

  gr$nodes_df$shape <- node_shapes
  gr$nodes_df$color <- node_edge_colours
  gr$nodes_df$fillcolor <- node_colours
  gr$nodes_df$width <- node_size
  gr$nodes_df$height <- node_size * 0.8
  gr$nodes_df$label <- node_labels

  # edge options
  gr$edges_df$color <- 'Gainsboro'
  gr$edges_df$fontname <- 'Helvetica'
  gr$edges_df$fontcolor <- 'gray'
  gr$edges_df$fontsize <- 11
  gr$edges_df$penwidth <- 3

  gr$edges_df$label <- edge_labels
  gr$edges_df$style <- edge_style

  # set the layout type
  gr$global_attrs$value[gr$global_attrs$attr == 'layout'] <- 'dot'
  # make it horizontal
  gr$global_attrs <- rbind(gr$global_attrs,
                           data.frame(attr = 'rankdir',
                                      value = 'LR',
                                      attr_type = 'graph'))


  print(DiagrammeR::render_graph(gr))

  invisible(gr)

}

