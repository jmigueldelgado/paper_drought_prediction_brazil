# This file run_hindcasts.R is part of the experiment scripts for the
# paper Pilz et al. (2018), HESS
# Copyright (C) 2018 Tobias Pilz
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


# This script runs the WASA-SED model over several sub-catchments (respecting upstream dependencies) and
# years of a given time period. For every sub-catchment and year, a number of meteo hindcast realisations
# is employed by the model and transformed into a signal of reservoir storage response. 
# For each year and realisation, the model is run from 1 January until 30 June starting with saved model states
# from the initial WASA runs based on observed meteorology and observed filling states of the strategic reservoirs.
#
# NOTE: for the hindcasts no observed intakes (file intake.dat) are used but parameterisation from reservoir.dat
# (median value of observations for each reservoir). If no obsered reservoir level was available for a certain year,
# the value of last year's 31 Dec from the initial run is taken.

### INITIALISATION ###---------------------------------------------------------

library(tidyverse)
library(lubridate)
library(doMC)
registerDoMC(5)

# requires subdirectories: <subcatchment>/<wasa_input_files>
dir_setup <- "../setup"

# directory with initial runs: <subcatchment>/<year>/<wasa_output>
dir_init <- "../runs_init"

# directory with meteo hindcasts, i.e. prepared time_series input files for WASA: <dir_meteo>/<realisation>/<wasa meteo input>
# requires four files: rain_daily.dat, humidity.dat, temperature.dat, radiation.dat
#dir_meteo <- "../meteo_hindcasts" # cluster
dir_meteo <- "../../data/rischid_share/hindcasts/meteo_biascor"

# output directory: <dir_out>/<subcatch>/<year>/<realisation>/<wasa_output>
dir_out <- "../runs_hindcasts_biascor"

# temporary directory containing model setup for current realisation (relative to working directory where this script is started from)
dir_temp <- "../tmp_run_dir"

# start and end dates of model runs (each year: run until 30 June)
date_start <- ymd("1981-01-01")
date_end <- ymd("2014-06-30")

# name of WASA-SED executabe
wasa_app <- "wasa"

# processing order of sub-catchments (some may depend on others)
subcatch <- c("Banabuiu", "Oros", "Salgado", "Castanhao", "Jaguaribe")

# dependencies: which sub-catchment gets inflows from which other sub-catchments + subbasin IDs
depends <- list(Banabuiu = NULL,
                Oros = NULL,
                Salgado = NULL,
                Castanhao = data.frame(Oros = 30, Salgado = 25),
                Jaguaribe = data.frame(Castanhao = 17, Banabuiu = 10))


### CALCULATIONS ###-----------------------------------------------------------

# sequence of years to be processed (as 1 Jan)
yrs <- seq.Date(date_start, date_end, by="year")
# realisations of meteo hindcasts
realis <- list.dirs(dir_meteo, full.names = F, recursive = F)

# loop over sub-catchments-----------------------------------------------------
for(s in subcatch) {
  
  # create sub-dir in dir_out
  dir.create(paste(dir_out, s, sep="/"), recursive = T, showWarnings = F)
  
  # loop over hindcast realisations--------------------------------------------
  loop_out <- foreach(r = realis) %dopar% {
    
    # prepare temporary directory containing current model input
    dir_setup_tmp <- tempfile(paste(s, r, "", sep="_"), tmpdir = dir_temp)
    dir.create(dir_setup_tmp, recursive = T)
    file.copy(paste(dir_setup, s, ".", sep="/"), dir_setup_tmp, recursive = T)
    # delete observed meteo input and intake.dat
    unlink(paste(dir_setup_tmp, "Time_series", c("humidity.dat", "temperature.dat", "rain_daily.dat", "radiation.dat", "intake.dat"), sep="/"))
    # copy hindcast realisation meteo input
    file.copy(paste(dir_meteo, r, c(c("humidity.dat", "temperature.dat", "rain_daily.dat", "radiation.dat")), sep="/"),
              paste(dir_setup_tmp, "Time_series", sep="/"))
    
    # prepare dependencies (subbasin_out.dat)
    if(!is.null(depends[[s]])) {
      # read river flow data from dependencies for current realisation
      dat_t <- map_dfr(grep(paste0("/", r, "/"), grep(paste(colnames(depends[[s]]), collapse = "|"),
                                     dir(dir_out, pattern = "River_Flow.out", recursive = T, full.names = T), value = T),
                             value=T), function(x) {
                               read.table(x, skip=1, header=T, check.names=F) %>%
                                 mutate(date = as.Date(paste(year, day, sep="-"), "%Y-%j")) %>%
                                 select(date, as.character(!!!depends[[s]][[nth(unlist(strsplit(x, "/")), -4)]])) %>%
                                 gather(key = subbas, value = value, -date) %>%
                                 mutate_if(is.factor, as.character)
                             })
      
      # check that all years are available
      r_yrs_miss <- which(!(format(yrs, "%Y") %in% unique(format(dat_t$date, "%Y"))))
      if(length(r_yrs_miss) > 0)
        stop(paste("For sub-catchment", s, "realisation", r, "the following years are missing in the dependencies:",
                   paste(format(yrs[r_yrs_miss], "%Y"), collapse = ", ")))

      # write into file
      dat_out <- dat_t %>%
        spread(key = "subbas", value = "value") %>%
        mutate(doy=as.integer(format(date, "%j")), date = sprintf(as.integer(format(date, "%d%m%Y")), fmt="%08d")) %>%
        select(date, doy, matches("[0-9]*"))
      colnames(dat_out)[c(1,2)] <- c("0", "0")
      writeLines(c("pre-specified	mean	daily	river	flow	[m3/s]	for	selected	sub-basins	(MAP-IDs)",
                   "Date	No.	of	days	Subbasin-ID."), paste(dir_setup_tmp, "Time_series", "subbasin_out.dat", sep="/"))
      write.table(dat_out, paste(dir_setup_tmp, "Time_series", "subbasin_out.dat", sep="/"), row.names = F, sep="\t", quote = F, append = T)
    }
    
    
    # loop over years----------------------------------------------------------
    for (yt in seq_along(yrs)) {
      y <- yrs[yt]
      
      # create sub-dir
      dir.create(paste(dir_out, s, year(y), r, sep="/"), recursive = T, showWarnings = F)
      
      # prepare reservoir input for this iteration
      file_res <- paste(dir_setup_tmp, "Reservoir", paste0("reservoir_", year(y), ".dat"), sep="/")
      if(!file.exists(file_res))
        stop(paste0("Could not find ", file_res, "!"))
      file.copy(file_res, paste(dir_setup_tmp, "Reservoir", "reservoir.dat", sep="/"), overwrite = T)
        # check if measurement of vol0 is available and use simulation value from last year if necessary
        dat_res <- read.table(paste(dir_setup_tmp, "Reservoir", "reservoir.dat", sep="/"), skip=2, header=F)
        dat_res_vol0 <- apply(dat_res, 1, function(dat_t) {
        if(dat_t[4] == -999 & dat_t[9] < year(y) & yt > 1) {
            dat_vol0_t <- read.table(paste0(dir_init, "/", s, "/", year(y)-1, "/res_", dat_t[1], "_watbal.out"), header = F, skip = 1)
            dat_vol0 <- last(dat_vol0_t[,16])/1000
        } else {
            dat_vol0 <- dat_t[4]
        }
        return(dat_vol0)
        })
        dat_res[,4] <- dat_res_vol0
        write(c("Specification of reservoir parameters",
                "Subasin-ID, minlevel[m], maxlevel[m], vol0([1000m**3]; unknown=-999), storcap[1000m**3], damflow[m**3/s], damq_frac[-], withdrawal[m**3/s], damyear[YYYY], maxdamarea[ha], damdead[1000m**3], damalert[1000m**3], dama[-], damb[-], qoutlet[m**3/s], fvol_bottom[-], fvol_over[-], damc[-], damd[-], elevbottom[m]"),
            file = paste(dir_setup_tmp, "Reservoir", "reservoir.dat", sep="/"), sep="\n")
        write.table(dat_res, paste(dir_setup_tmp, "Reservoir", "reservoir.dat", sep="/"), row.names=F, col.names = F, sep="\t", quote=F, append = T)
      
      # dir_out relative to dir_setup_tmp (needed for do.dat)
      dir_setup_tmp_abs <- unlist(strsplit(normalizePath(dir_setup_tmp, mustWork = T), "/"))
      dir_out_abs <- unlist(strsplit(normalizePath(dir_out, mustWork = T), "/"))
      common_path <- which(dir_out_abs %in% dir_setup_tmp_abs)
      if(any(diff(common_path) > 1)) common_path <- common_path[1:which(diff(common_path) > 1)[1]]
      dir_out_wasa <- paste(paste(rep("..", length(dir_setup_tmp_abs)-length(common_path)), collapse = "/"),
                            paste(dir_out_abs[-common_path], collapse = "/"),
                            sep="/")
      
      # prepare do.dat
      dodat <- readLines(paste(dir_setup_tmp, "do.dat", sep="/"))
      dodat[2] <- "./"
      dodat[3] <- paste(dir_out_wasa, s, year(y), r, "", sep="/")
      dodat[4] <- paste0(year(y), "\t//tstart (start year of simulation)")
      dodat[5] <- paste0(year(y), "\t//tstop (end year of simulation)")
      dodat[6] <- paste0(month(y), "\t//mstart (start month of simulation)")
      dodat[7] <- "06\t//mstop (end month of simulation)"
      dodat[36] <- ".t. .f. //load state of storages from files (if present) at start (optional)"
      dodat[37] <- ".t. .f. //save state of storages to files after simulation period (optional)"
      writeLines(dodat, paste(dir_setup_tmp, "do.dat", sep="/"))
      
      # make sure required output is generated
      outfiles <- c("This files describe which output files are generated",
                    "res_watbal",
                    "River_Flow")
      writeLines(outfiles, paste(dir_setup_tmp, "outfiles.dat", sep="/"))
      
    # make sure intake is NOT used
    if(file.exists(paste(dir_setup_tmp, "Time_series/intake.dat", sep="/"))) {
        file.copy(paste(dir_setup_tmp, "Time_series/intake.dat", sep="/"), paste(dir_setup_tmp, "Time_series/intake_t.dat", sep="/"), overwrite = T)
        unlink(paste(dir_setup_tmp, "Time_series/intake.dat", sep="/"), force = T)
    }
      
      # copy storage files from init runs to output directory
      files_stor <- grep("*.stat$", dir(paste(dir_init, s, format(yrs[yt]-years(1), "%Y"), sep="/"), full.names = T), value = T)
      file.copy(files_stor, paste(dir_out, s, year(y), r, sep="/"), overwrite = T)
      
      # run WASA
      run_log <- system(command = paste0(wasa_app, " ", dir_setup_tmp, "/do.dat"), intern = T)
      if(any(grepl("error", run_log, ignore.case = T))) {
        writeLines(run_log, paste0("run_", s, "_", year(y), ".log"))
        stop(paste("WASA returned a runtime error, see log file:", paste0("run_", s, "_", year(y), ".log")))
      }
    } # loop over years
    
    NULL
  } # loop over realisations

} # loop over subcatchments
