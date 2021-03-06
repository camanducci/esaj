
#' Makes a parser
#' @export
make_parser <- function() {
  list(name = NULL, getter = NULL) %>% rlang::set_attrs("class" = "parser")
}

#' Parses parts
#' @param parser A parser returned by [make_parser()]
#' @export
parse_parts <- function(parser) {

  # Check class
  stopifnot(class(parser) == "parser")

  # Function for getting parts
  get_parts <- function(html) {
    html %>%
      xml2::xml_find_all("//*[@id='tablePartesPrincipais']") %>%
      rvest::html_table(fill = TRUE) %>%
      purrr::pluck(1) %>%
      dplyr::as_tibble() %>%
      dplyr::mutate(
        X2 = stringr::str_split(X2, "&nbsp"),
        id = 1:nrow(.)) %>%
      tidyr::unnest(X2) %>%
      dplyr::mutate(
        part = str_replace_all(X1, "[^a-zA-Z]", ""),
        role = stringr::str_extract(dplyr::lag(X2), "\\t [a-zA-Z]+:"),
        role = str_replace_all(role, "[^a-zA-Z]", ""),
        role = ifelse(is.na(role), part, role),
        name = str_replace_all(X2, " ?\\n.+", "")) %>%
      dplyr::select(id, name, part, role)
  }

  # Add get_parts to getters
  purrr::list_merge(parser, name = "parts", getter = get_parts)
}

#' Parses data
#' @param parser A parser returned by [make_parser()]
#' @export
parse_data <- function(parser) {

  # Check class
  stopifnot(class(parser) == "parser")

  # Function for getting data
  get_data <- function(html) {
    html %>%
      xml2::xml_find_all("//*[@class='secaoFormBody']") %>%
      rvest::html_table(fill = TRUE) %>%
      purrr::pluck(2) %>%
      dplyr::as_tibble() %>%
      dplyr::filter(!(is.na(X2) & is.na(X3))) %>%
      dplyr::select(-X3) %>%
      dplyr::add_row(
        X1 = "Situa\u00E7\u00E3o",
        X2 = stringr::str_extract(.[1, 2], "[A-Za-z]+$")) %>%
      dplyr::mutate(
        X1 = str_replace_all(X1, ":", ""),
        X2 = str_replace_all(X2, " ?[\\n\\t].+", ""),
        X2 = str_replace_all(X2, "\\n", "")) %>%
      purrr::set_names("data", "value")
  }

  # Add get_data to getters
  purrr::list_merge(parser, name = "data", getter = get_data)
}

#' Parses movements
#' @param parser A parser returned by [make_parser()]
#' @export
parse_movs <- function(parser) {

  # Check class
  stopifnot(class(parser) == "parser")

  # Function for getting movements
  get_movs <- function(html) {
    html %>%
      xml2::xml_find_all("//*[@id='tabelaTodasMovimentacoes']") %>%
      rvest::html_table(fill = TRUE) %>%
      purrr::pluck(1) %>%
      dplyr::as_tibble() %>%
      dplyr::mutate(
        X1 = lubridate::dmy(X1),
        X3 = str_replace_all(X3, "[\\t\\n]", ""),
        X3 = str_replace_all(X3, "\\r", " "),
        X3 = str_replace_all(X3, " +", " ")) %>%
      dplyr::select(-X2) %>%
      purrr::set_names("movement", "description")
  }

  # Add get_movs to getters
  purrr::list_merge(parser, name = "movs", getter = get_movs)
}

#' Parses decisions
#' @param parser A parser returned by [make_parser()]
#' @export
parse_decisions <- function(parser){

  # Check class
  stopifnot(class(parser) == "parser")

  # Function for getting decisions
  get_decisions <- function(html) {

    #Gets all eligible tables
    tables <- html %>%
      xml2::xml_find_all("//table[@style='margin-left:15px; margin-top:1px;']")

    #Beginning of the table
    first_table <- tables %>%
      rvest::html_text() %>%
      stringr::str_which("Situa\u00e7\u00e3o do julgamento") %>%
      max()

    #Check if first_table is Inf
    if(is.infinite(first_table)){return(dplyr::data_frame(date = NA, decision = NA))}

    #End of the table
    last_table <- length(tables)

    tables[first_table:last_table] %>%
      rvest::html_table(fill = TRUE) %>%
      dplyr::bind_rows() %>%
      dplyr::as_tibble() %>%
      dplyr::mutate(
        X1 = lubridate::dmy(X1),
        X2 = stringr::str_replace_all(X2, "[:space:]+"," "),
        X3 = stringr::str_replace_all(X3, "[:space:]+", " ")) %>%
      dplyr::select(-X2) %>%
      dplyr::filter(!is.na(X1)) %>%
      purrr::set_names("date", "decision")
  }

  # Add get_decisions to getters
  purrr::list_merge(parser, name = "decisions", getter = get_decisions)
}

hidden_lawsuit <- function(html) {
  # checks if lawsuit has secret of justice
  !is.na(rvest::html_node(html, "#popupSenhaProcesso"))
}

#' Runs a parser
#' @param file A character vector with the paths to one ore more files
#' @param parser A parser returned by [make_parser()]
#' @param path The path to a directory where to save RDSs
#' @param cores The number of cores to be used when parsing
#' @export
run_parser <- function(file, parser, path = ".", cores = 1) {

  # Check if parser is a parser
  stopifnot(class(parser) == "parser")

  # Given a parser and a file, apply getters
  apply_getters <- function(file, parser_path) {

    # Resolve parallelism problem
    parser <- parser_path$parser
    path <- parser_path$path

    # Apply all getters
    html <- xml2::read_html(file)

    if (hidden_lawsuit(html)) {
      empty_cols <- parser_path$parser$name %>%
        purrr::map(~list(tibble::tibble())) %>%
        purrr::set_names(parser_path$parser$name) %>%
        tibble::as_tibble()
      out <- tibble::tibble(id = tools::file_path_sans_ext(basename(file)),
                            file, hidden = TRUE) %>%
        dplyr::bind_cols(empty_cols)
    } else {
      out <- parser$getter %>%
        purrr::invoke_map(list(list(html = html))) %>%
        purrr::set_names(parser$name) %>%
        purrr::modify(list) %>%
        dplyr::as_tibble() %>%
        dplyr::mutate(
          file = file,
          id = tools::file_path_sans_ext(basename(file)),
          hidden = FALSE) %>%
        dplyr::select(id, file, hidden, dplyr::everything())
    }

    # Write and return
    readr::write_rds(out, stringr::str_c(path, "/", out$id, ".rds"))
    return(out)
  }

  # Create path if necessary
  dir.create(path, showWarnings = FALSE, recursive = TRUE)

  # Apply getters to all files
  parser_path <- list(parser = parser, path = path)
  parallel::mcmapply(
    apply_getters, file, list(parser_path = parser_path),
    SIMPLIFY = FALSE, mc.cores = cores) %>%
    dplyr::bind_rows()
}

# Print parser
print.parser <- function(x, ...) {
  if (length(x$name) == 0) {
    cat("An empty parser\n")
  }
  else {
    cat("A parser for the following objects:\n")
    purrr::walk(x$name, ~cat("- ", .x, "\n", sep = ""))
  }
}
