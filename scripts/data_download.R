library(jsonlite)
library(httr)
library(readxl)
library(dplyr)
library(purrr)
library(lubridate)
library(readr)

source("scripts/helper_functions.R")

# Download data passport from source
baseUrl <- "https://data.gov.ua/api/3/action/package_show?id="
uiid <- "f5095ab0-5312-480d-9090-f8f2a42a023c"
apiUrl <- paste0(baseUrl, uiid)

data_pass <- fromJSON(apiUrl, simplifyVector = TRUE)$result
resources <- data_pass$resources

# Download data
# Ship calls
col_names_call = c("port_name", "num", "arrival_date", "arrival_time", "departure_date", 
              "departure_time", "ship_id", "ship_name", "ship_type", "ship_flag", "dwt",
              "call_purpose", "cargo_type", "volume", "agent")
col_types_call = c("text", "numeric", "text", "text", "text", "text", "text", "text", "text",
                   "text", "numeric", "text", "text", "numeric", "text")
df_call <- map2(resources$url, resources$name,
                   ~ read_sheet(.x, .y, sheet = 1, col_names_call, col_types_call)) |> 
  bind_rows() |> 
  mutate(arrival_date = dmy(arrival_date), 
         departure_date = dmy(departure_date)) |> 
  select(-num)

write_csv(df_call, "data/ship calls.csv")

# Handling volumes
col_names_vol = c("port_name", "year", "month", "port_operator", "berth_no", "cargo_type", 
                  "direction", "volume", "unit")
col_types_vol = c("text", "numeric", "text", "text", "text", "text", "text", "numeric", "text")

df_volume <- map2(resources$url, resources$name,
                   ~ read_sheet(.x, .y, sheet = 2, col_names_vol, col_types_vol)) |> 
  bind_rows() |> 
  mutate(date = ymd(paste(year, ukr_months[month], 1, sep="-"))) |> 
  select(-c(year, month)) |> 
  relocate("date", .after = "port_name")

write_csv(df_volume, "data/handling volumes.csv")

