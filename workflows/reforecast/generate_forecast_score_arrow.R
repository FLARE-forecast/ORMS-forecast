#' Score a forecast using score4cast package and arrow
#' @param targets_file observation file
#' @param forecast_df forecast file
#' @output_directory directory to save scored file
#' @return
#' @export
#'
#' @examples
generate_forecast_score_arrow <- function(targets_df,
                                          forecast_df,
                                          use_s3 = FALSE,
                                          bucket = NULL,
                                          endpoint = NULL,
                                          local_directory = NULL,
                                          variable_types = "state"){


  if(use_s3){

    output_directory <- arrow::s3_bucket(bucket, endpoint_override = endpoint)

  }else{
    if(is.null(local_directory)){
      stop("scoring function needs local_directory if use_s3=FALSE")
    }
    output_directory <- arrow::SubTreeFileSystem$create(local_directory)
  }


  df <- forecast_df |>
    dplyr::filter(variable_type %in% variable_types) |>
    dplyr::mutate(family = as.character(family)) |>
    score4cast::crps_logs_score(targets_df, extra_groups = c('depth')) |>
    dplyr::mutate(horizon = datetime-lubridate::as_datetime(reference_datetime)) |>
    dplyr::mutate(horizon = as.numeric(lubridate::as.duration(horizon),
                                       units = "seconds"),
                  horizon = horizon / 86400)

  df <- df |> dplyr::mutate(reference_date = lubridate::as_date(reference_datetime))

  arrow::write_dataset(df, path = s3, partitioning = c("site_id","model_id","reference_date"))

}
