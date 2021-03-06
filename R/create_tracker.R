
#' Creates Monthly Tracker (Pre Analysis and PfM Commentary)
#'
#' Compares the performance across a given standard for each Trading Party
#' by Standard and compares IPRP performance versus planned milestones.
#' This is done prior to analysis and Pfm commentary being added.
#'
#' @param period date
#' @param my.dir character
#' @param rda.outputs character
#' @param period.only logical
#' @param save.output logical
#' @param keep.vars logical
#' @param iprp.list character
#' @param filter.category character
#' @param dir.tracking character
#' @param standard.data dataframe
#' @param iprp.plans dataframe
#' @param tracking.sheet dataframe
#' @param standard character
#'
#' @return
#' @export
#'
#' @importFrom magrittr %>%
#'
#' @examples

create_tracker <- function(
  period = Sys.Date() %m-% months(1),
  my.dir = getwd(),
  standard.data,
  iprp.plans,
  tracking.sheet,
  standard,
  rda.outputs = paste0(my.dir, "/data/rdata"),
  dir.tracking,
  period.only = TRUE,
  save.output = TRUE,
  keep.vars = FALSE,
  iprp.list,
  filter.category = c("IPRP: on-track", "Normal monitoring")
  ) {

  # Setting parameters ------------------------------------------------------

  thing <- 0

  period <- as.Date(period)

  lubridate::day(period) <- 1

  if (keep.vars) {
    var_list <- NULL
  } else {
    var_list <-
      c(
        "Date", "SecondaryCategory", "Trading.Party.ID", "Standard",
        "PerformanceMeasure",
        "Action","Rationale", "PFM_Commentary", "ActiveIPRP", "IPRPend",
        "MilestoneFlag", "PerfFlag3m", "PerfFlag6m", "OnWatch",
        "OnWatchIPRPend",  "Consistency", "PerfRating"
      )
    }


  # Importing data ----------------------------------------------------------

  IPRP_plans <- iprp.plans %>%
    dplyr::mutate(
      Date = as.Date(Date, format = "%d/%m/%Y")
      ) %>%
    dplyr::group_by(
      Trading.Party.ID, Standard, PerformanceMeasure
      ) %>%
    dplyr::mutate(
      PlanEndDate = max(Date)
      ) %>%
    dplyr::ungroup()

  tracking_sheet <- tracking.sheet %>%
    dplyr::mutate(
      Date = as.Date(Date, format = "%d/%m/%Y") %m-% months(-1)
      ) %>%
    dplyr::select(
      Date, Action, Trading.Party.ID, Standard, PerformanceMeasure, Template_Sent, Response_Received
    )


  # Creating monthly tracking sheet -------------------------

  monthly_tracking <- standard.data %>%
    dplyr::left_join(
      IPRP_plans,
      by = c("Date", "Standard", "Trading.Party.ID", "PerformanceMeasure")
    ) %>%
    dplyr::left_join(
      tracking_sheet,
      by = c("Date", "Trading.Party.ID", "Standard", "PerformanceMeasure")
    ) %>%
    dplyr::mutate(
      Action = tolower(Action),
      Delta = Performance - Planned_Perf,
      DeltaQuant = Delta / Planned_Perf,
      Performance = as.numeric(format(Performance, digits = 1)),
      Planned_Perf = as.numeric(format(Planned_Perf, digits = 1)),
      Status = dplyr::case_when(
        (DeltaQuant > 0.05) ~ "Outperform",
        (DeltaQuant <= 0.05 & DeltaQuant >= -0.05) ~ "OnTrack",
        (DeltaQuant < -0.05) ~ "OffTrack"
      ),
      OnWatch = Action == "watch",
      OnWatchIPRPend = Action == "de-escalate" | Action == "watch_iprpend",
      MilestoneFlag = Performance < Planned_Perf,
      IPRPend = PlanEndDate == Date,
      Pending = Template_Sent != "" & Response_Received == "",
      UnderReview =
        Action == "review" | Action == "re-submit" | Action == "extend" | Action == "escalate",
      ActiveIPRP = !is.na(Status),
      InactiveIPRP = IPRPend | Pending | (UnderReview & !ActiveIPRP),
      IPRP = ActiveIPRP | InactiveIPRP,
      IPRPeligible = Standard %in% iprp_list
    ) %>%
    droplevels() %>%
    dplyr::arrange(Trading.Party.ID, Standard, Date) %>%
    dplyr::group_by(Trading.Party.ID, Standard, PerformanceMeasure) %>%
    dplyr::mutate(
      PerfFlag3m = zoo::rollapply(BelowPeer, 3, mean, align = "right", fill = NA) == 1,
      PerfFlag6m = zoo::rollapply(BelowPeer, 6, mean, align = "right", fill = NA) >= 0.5,
      rolling.sd = zoo::rollapply(Performance, 6, sd, align = "right", fill = NA),
      rolling.mean = zoo::rollapply(Performance, 6, mean, align = "right", fill = NA),
      Consistency =
        dplyr::case_when(
          rolling.sd < 0.01 ~ "Very Consistent",
          rolling.sd >= 0.01 & rolling.sd < 0.02 ~ "Consistent",
          rolling.sd >= 0.02 & rolling.sd < 0.05 ~ "Inconsistent",
          rolling.sd > 0.05 ~ "Very Inconsistent",
          TRUE ~ "Insufficient data"
        ),
      PerfRating =
        dplyr::case_when(
          rolling.mean >= 0.9 ~ "Very Good",
          rolling.mean < 0.9 & rolling.mean >= 0.8 ~ "Good",
          rolling.mean < 0.8 & rolling.mean >= 0.7 ~ "Poor",
          rolling.mean < 0.7 ~ "Very Poor",
          TRUE ~ "Insufficient data"
        ),
      SumPerf3m = tidyr::replace_na(zoo::rollapply(PerfFlag3m, 12, sum, align = "right", fill = NA), 0),
      SumPerf6m = tidyr::replace_na(zoo::rollapply(PerfFlag6m, 12, sum, align = "right", fill = NA), 0)
    ) %>%
    dplyr::ungroup() %>%
    dplyr::mutate_if(is.logical, ~tidyr::replace_na(., FALSE)) %>%
    dplyr::mutate(
      PrimaryCategory =
        dplyr::case_when(
          !IPRP ~ "Monitoring",
          IPRP ~ "Resolution"
        ),
      SecondaryCategory =
        dplyr::case_when(
          !IPRP & OnWatch ~ "Watch: performance",
          OnWatchIPRPend ~ "Watch: IPRP end",
          !IPRP & !OnWatch & PerfFlag6m & !PerfFlag3m ~ "Performance flag: 6 month",
          !IPRP & !OnWatch & PerfFlag3m ~ "Performance flag: 3 month",
          ActiveIPRP & MilestoneFlag & !IPRPend ~ "IPRP: off-track",
          ActiveIPRP & !MilestoneFlag & !IPRPend ~ "IPRP: on-track",
          IPRPend ~ "IPRP: end",
          IPRP & UnderReview ~ "IPRP: under review",
          TRUE ~ "Normal monitoring"
        ),
      Action = "tbd",
      Rationale = "tbd",
      PFM_Commentary = "tbd"
    ) %>%
    dplyr::filter(
      !(SecondaryCategory %in% filter.category)
    ) %>%
    {if (!keep.vars) {
      dplyr::select(., var_list)
    } else {
      dplyr::select(., dplyr::everything())
    }
    } %>%
    {if (period.only) {
      dplyr::filter(., Date == period)
    } else {
      dplyr::mutate(., date.stamp = Sys.Date())
    }
    }

  if (save.output) {
    utils::write.csv(monthly_tracking, paste0(dir.tracking, "/", format(period, "%Y-%m"), "_monthly-tracking-", "standard", ".csv"), row.names = FALSE)
    saveRDS(monthly_tracking, file = paste0(rda.outputs, "/monthly_tracking_", standard, "_pre.Rda"))
  }

  invisible(monthly_tracking)

}
