# install.packages(c("httr2", "jsonlite"))  # si hace falta
library(httr2)
library(jsonlite)

geolocalizador_client <- function(base_url = "http://localhost:8000") {
  .mk <- function(path, query = list()) {
    request(base_url) |>
      req_url_path_append(path) |>
      req_url_query(!!!query)
  }
  .perform <- function(req) {
    # Manejo de errores claro
    tryCatch({
      resp <- req |> req_perform()
      resp |> resp_body_json(simplifyVector = TRUE)
    }, error = function(e) {
      stop(sprintf("Solicitud falló: %s\nURL: %s",
                   conditionMessage(e),
                   as.character(req_url(req))), call. = FALSE)
    })
  }
  
  list(
    # GET /health
    health = function() {
      .perform(.mk("health"))
    },
    
    # GET /sugerencias?qstr=&limit=
    sugerencias = function(qstr = "", limit = 20L) {
      stopifnot(is.character(qstr), length(qstr) == 1L)
      stopifnot(is.numeric(limit), limit >= 1, limit <= 50)
      .perform(.mk("sugerencias", list(qstr = qstr, limit = as.integer(limit))))
    },
    
    # GET /sugerencias_es2?qstr=&limit=
    sugerencias_es2 = function(qstr = "", limit = 10L) {
      stopifnot(is.character(qstr), length(qstr) == 1L)
      stopifnot(is.numeric(limit), limit >= 1, limit <= 50)
      .perform(.mk("sugerencias_es2", list(qstr = qstr, limit = as.integer(limit))))
    },
    
    # GET /geocode_direccion?calle=&altura=&numero_cal=&fallback=
    geocode_direccion = function(altura,
                                 calle = NULL,
                                 numero_cal = NULL,
                                 fallback = FALSE) {
      stopifnot(is.numeric(altura), length(altura) == 1L, !is.na(altura))
      stopifnot(is.logical(fallback), length(fallback) == 1L)
      q <- list(altura = as.integer(altura), fallback = fallback)
      if (!is.null(calle))      q$calle      <- as.character(calle)
      if (!is.null(numero_cal)) q$numero_cal <- as.character(numero_cal)
      .perform(.mk("geocode_direccion", q))
    },
    
    # GET /geocode_interseccion?calle1=&calle2=
    geocode_interseccion = function(calle1, calle2) {
      stopifnot(is.character(calle1), length(calle1) == 1L, nchar(calle1) > 0)
      stopifnot(is.character(calle2), length(calle2) == 1L, nchar(calle2) > 0)
      .perform(.mk("geocode_interseccion", list(calle1 = calle1, calle2 = calle2)))
    }
  )
}
