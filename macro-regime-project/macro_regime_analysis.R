# =============================================================================
# Macro Regime Analysis: How Asset Classes Perform Across Growth/Inflation Regimes
# Author: Christopher Ahle
#
# Question: How do stocks, Treasuries, credit, TIPS, gold and commodities perform
# when growth and inflation are rising or falling, and what does today's regime
# imply for a portfolio benchmarked to 80% VTI / 20% BND?
#
# Data: FRED (CPI, industrial production) and Yahoo Finance (ETF prices),
# pulled through the tidyquant package. No API keys needed.
# =============================================================================

# ---- 0. Setup ---------------------------------------------------------------
# Run this line once, then comment it out:
# install.packages(c("tidyquant", "tidyverse", "lubridate", "scales"))

library(tidyquant)
library(tidyverse)
library(lubridate)
library(scales)

START      <- "2005-01-01"          # pull extra history so year-over-year math works
ANALYSIS   <- as.Date("2007-05-01") # first month every ETF exists (HYG launched Apr 2007)
LOOKBACK   <- 6                     # months used to judge if growth/inflation are rising
LAG        <- 1                     # months between macro data and returns (avoids look-ahead)

# ---- 1. Macro data: classify each month into a regime -----------------------
# CPIAUCSL = consumer price index; INDPRO = industrial production (growth proxy)
# Downloads FRED's public CSV directly (no API key needed). Forces HTTP/1.1,
# which avoids the "HTTP/2 stream error" some Macs get from FRED.
# If FRED times out, open the link printed below in your browser, save the file
# as "fred_data.csv" in this project folder, and run the script again.
fred_get <- function(ids, local_file = "fred_data.csv") {
  url <- paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=",
                paste(ids, collapse = ","))
  if (file.exists(local_file)) {
    message("Using saved FRED file: ", local_file)
    src <- local_file
  } else {
    src <- tempfile(fileext = ".csv")
    ok <- FALSE
    for (attempt in 1:3) {
      ok <- tryCatch({
        curl::curl_download(url, src, handle = curl::new_handle(
          http_version = 2, connecttimeout = 30, timeout = 120))
        TRUE
      }, error = function(e) { message("FRED attempt ", attempt, " failed: ", conditionMessage(e)); FALSE })
      if (ok) break
      Sys.sleep(3)
    }
    if (!ok) stop("\nFRED did not respond. Open this link in your browser:\n  ", url,
                  "\nSave the file into your project folder as fred_data.csv, then run the script again.")
  }
  out <- readr::read_csv(src, show_col_types = FALSE, na = c("", "NA", "."))
  names(out)[1] <- "date"
  out %>% mutate(date = as.Date(date))
}

macro <- fred_get(c("CPIAUCSL", "INDPRO")) %>%
  filter(date >= as.Date(START)) %>%
  arrange(date) %>%
  mutate(
    cpi_yoy   = CPIAUCSL / lag(CPIAUCSL, 12) - 1,          # inflation rate
    ip_yoy    = INDPRO   / lag(INDPRO, 12)   - 1,          # growth rate
    infl_up   = cpi_yoy - lag(cpi_yoy, LOOKBACK) > 0,      # is inflation accelerating?
    growth_up = ip_yoy  - lag(ip_yoy,  LOOKBACK) > 0,      # is growth accelerating?
    regime = case_when(
       growth_up & !infl_up ~ "Goldilocks (growth up, inflation down)",
       growth_up &  infl_up ~ "Reflation (growth up, inflation up)",
      !growth_up &  infl_up ~ "Stagflation (growth down, inflation up)",
      !growth_up & !infl_up ~ "Slowdown (growth down, inflation down)"
    )
  ) %>%
  filter(!is.na(regime)) %>%
  transmute(month = floor_date(date, "month"), cpi_yoy, ip_yoy, regime)

# What regime are we in now? (most recent data, before the lag)
cat("\nMost recent regime readings:\n")
print(tail(macro, 6))

# ---- 2. Asset returns -------------------------------------------------------
tickers <- c(
  "VTI",  # U.S. total stock market (fund equity benchmark)
  "BND",  # U.S. aggregate bonds (fund bond benchmark)
  "SHY",  # 1-3 year Treasuries
  "IEF",  # 7-10 year Treasuries
  "TLT",  # 20+ year Treasuries
  "TIP",  # inflation-protected Treasuries
  "LQD",  # investment-grade corporate bonds
  "HYG",  # high-yield corporate bonds
  "GLD",  # gold
  "DBC"   # broad commodities (fund alternatives benchmark)
)

rets <- tq_get(tickers, get = "stock.prices", from = START) %>%
  group_by(symbol) %>%
  tq_transmute(select = adjusted, mutate_fun = periodReturn,
               period = "monthly", col_rename = "ret") %>%
  ungroup() %>%
  mutate(month = floor_date(date, "month")) %>%
  select(month, symbol, ret)

# Fund benchmark: 80% VTI / 20% BND, rebalanced monthly
bench <- rets %>%
  filter(symbol %in% c("VTI", "BND")) %>%
  pivot_wider(names_from = symbol, values_from = ret) %>%
  drop_na() %>%
  transmute(month, symbol = "80/20 Benchmark", ret = 0.8 * VTI + 0.2 * BND)

all_rets <- bind_rows(rets, bench)

# ---- 3. Join returns to the regime known at the time ------------------------
regimes_lagged <- macro %>% mutate(month = month %m+% months(LAG))

df <- all_rets %>%
  inner_join(regimes_lagged, by = "month") %>%
  filter(month >= ANALYSIS) %>%
  drop_na(ret)

# How often has each regime occurred?
cat("\nMonths in each regime:\n")
print(df %>% distinct(month, regime) %>% count(regime))

# ---- 4. Performance by regime -----------------------------------------------
summary_tbl <- df %>%
  group_by(regime, symbol) %>%
  summarise(
    months       = n(),
    ann_return   = mean(ret) * 12,
    ann_vol      = sd(ret) * sqrt(12),
    return_per_risk = ann_return / ann_vol,
    hit_rate     = mean(ret > 0),
    worst_month  = min(ret),
    .groups = "drop"
  ) %>%
  arrange(regime, desc(ann_return))

print(summary_tbl, n = 100)
write_csv(summary_tbl, "regime_summary.csv")

# ---- 5. Charts --------------------------------------------------------------
order_assets <- c("VTI", "80/20 Benchmark", "BND", "SHY", "IEF", "TLT",
                  "TIP", "LQD", "HYG", "GLD", "DBC")

heat <- summary_tbl %>%
  mutate(symbol = factor(symbol, levels = order_assets)) %>%
  ggplot(aes(x = symbol, y = regime, fill = ann_return)) +
  geom_tile(color = "white") +
  geom_text(aes(label = percent(ann_return, accuracy = 0.1)), size = 3) +
  scale_fill_gradient2(low = "#B2182B", mid = "white", high = "#2166AC",
                       midpoint = 0, labels = percent) +
  labs(title = "Average annualized return by macro regime",
       subtitle = paste0("Monthly data, ", format(ANALYSIS, "%b %Y"),
                         " to present. Regimes from 6-month change in CPI and industrial production (FRED)."),
       x = NULL, y = NULL, fill = "Annualized\nreturn") +
  theme_minimal(base_size = 11) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))
print(heat)
ggsave("regime_heatmap.png", heat, width = 11, height = 5, dpi = 200)

# Timeline of regimes (shows when each one happened: 2008, 2020, 2022, now)
timeline <- macro %>%
  filter(month >= ANALYSIS) %>%
  ggplot(aes(x = month, y = 1, fill = regime)) +
  geom_tile() +
  scale_fill_manual(values = c(
    "Goldilocks (growth up, inflation down)"  = "#4DAF4A",
    "Reflation (growth up, inflation up)"     = "#FF7F00",
    "Stagflation (growth down, inflation up)" = "#E41A1C",
    "Slowdown (growth down, inflation down)"  = "#377EB8")) +
  labs(title = "Macro regime history", x = NULL, y = NULL, fill = NULL) +
  theme_minimal(base_size = 11) +
  theme(axis.text.y = element_blank(), panel.grid = element_blank(),
        legend.position = "bottom") +
  guides(fill = guide_legend(nrow = 2))
print(timeline)
ggsave("regime_timeline.png", timeline, width = 11, height = 3, dpi = 200)

# ---- 6. Your analysis (write this part yourself) ------------------------------
# Look at the stagflation row: which assets held up, which did not?
# Did Treasuries hedge stocks in every regime, or fail in some?
# What regime are we in now, and what does history say for the 80/20 benchmark?
# Limitations: simple regime rule, one growth proxy, ~20 years of data,
# averages hide big individual episodes (2008, 2020, 2022).