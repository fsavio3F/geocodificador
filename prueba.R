library(tidyr)
library(dplyr)

# Ejecutar llamadas (mejor con manejo de errores)
safe_geocode <- function(calle, altura) {
  tryCatch(
    api$geocode_direccion(calle = calle, altura = altura),
    error = function(e) NULL
  )
}

results <- lapply(seq_len(nrow(sso_direc)), function(i) {
  safe_geocode(sso_direc$calle[i], sso_direc$altura[i])
})

# Unir las respuestas con el data.frame original
sso_direc_out <- sso_direc %>%
  mutate(api_result = map(results, ~ if (is.null(.x)) tibble() else .x)) %>%
  unnest_wider(api_result, names_sep = "_api_")


sso_direc_out <- filter(sso_direc_out, partido == "Tres de Febrero")

map <- sso_direc_out |> 
  filter(!is.na(api_result_api_lon)) |> 
  sf::st_as_sf(coords = c("api_result_api_lon", "api_result_api_lat"), crs = 4326)



sso_direc_sf <- sso_direc_out %>%
  mutate(
    api_result_api_lat = as.numeric(api_result_api_lat),
    api_result_api_lon = as.numeric(api_result_api_lon)
  ) %>%
  filter(!is.na(api_result_api_lat), !is.na(api_result_api_lon)) %>%
  sf::st_as_sf(coords = c("api_result_api_lon", "api_result_api_lat"), crs = 4326) |> 
  select(-8)


mapview::mapview(sso_direc_sf)
sf::st_write(sso_direc_sf, "sso.geojson")
