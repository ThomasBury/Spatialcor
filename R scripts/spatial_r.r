library(spdep)
library(maptools)
library(leaflet)
library(viridis)
library(RColorBrewer)
library(mgcv)
library(data.table)

dir_path <- file.path("c:", "Users", "xxxx", "xxxxx", "R",
                      "Spatial stat test")
setwd(dir_path)
# Assign the number of cores
nbr_cores <- detectCores() - 1 # leave one core for the OS
cl <- makeCluster(nbr_cores) 

chi.poly <- readShapePoly('foreclosures.shp')
class(chi.poly)
str(slot(chi.poly,"data"))
summary(chi.poly@data$violent)
plot(chi.poly)


leaflet(chi.poly) %>%
  addPolygons(stroke = FALSE, fillOpacity = 0.5, smoothFactor = 0.5) %>%
  addTiles() #adds a map tile, the default is OpenStreetMap

qpal<-colorQuantile("inferno", chi.poly@data$violent, n=9) 

leaflet(chi.poly) %>%
  addPolygons(stroke = FALSE, fillOpacity = .8, smoothFactor = 0.2, color = ~qpal(violent)
  ) %>%
  addTiles()


# Spatial stat
## OLS

chi.ols<-lm(violent~est_fcs_rt+bls_unemp, data=chi.poly@data)
summary(chi.ols)

#The problem with ignoring the spatial structure of the data implies that the OLS estimates 
#in the non spatial model may be biased, inconsistent or inefficient


## Spatial regression

list.queen<-poly2nb(chi.poly, queen=TRUE) # neighbors: all the touching nodes, other choices possible
W<-nb2listw(list.queen, style="W", zero.policy=TRUE)
W

plot(W,coordinates(chi.poly))

coords<-coordinates(chi.poly)
W_dist<-dnearneigh(coords,0,1,longlat = FALSE)

### Testing the spatial correlation

moran.lm<-lm.morantest(chi.ols, W, alternative="two.sided")
print(moran.lm)


LM<-lm.LMtests(chi.ols, W, test="all")
print(LM)

## Spatial autoregression

chi.sar<-lagsarlm(violent~est_fcs_rt+bls_unemp, data=chi.poly@data, W)
summary(chi.sar)

## Spatial error model

chi.sem<-errorsarlm(violent~est_fcs_rt+bls_unemp, data=chi.poly@data, W)
summary(chi.sem)


## Compare the OLS and SAR
range01 <- function(x, na.rm = T){2*(x - min(x, na.rm = na.rm)) / (max(x, na.rm=na.rm) - min(x, na.rm=na.rm))-1}
n_cols <- 9
spectral_col <- colorRampPalette(brewer.pal(9,"Spectral"))(n_cols)

chi.poly@data$chi.ols.res<-resid(chi.ols) #residuals ols
chi.poly@data$chi.ols.fval <- chi.ols$fitted.values
# spplot(chi.poly,"chi.ols.res", at=seq(min(chi.poly@data$chi.ols.res,na.rm=TRUE),
#                                       max(chi.poly@data$chi.ols.res,na.rm=TRUE),
#                                       length=n_cols),col.regions=spectral_col)

chi.poly@data$chi.sar.res<-resid(chi.sar) #residual sar 
chi.poly@data$chi.sar.fval <- chi.sar$fitted.values
# spplot(chi.poly,"chi.sar.res", at=seq(min(chi.poly@data$chi.sar.res,na.rm=TRUE),
#                                       max(chi.poly@data$chi.sar.res,na.rm=TRUE),
#                                       length=n_cols),col.regions=spectral_col)

chi.poly@data$chi.sem.res<-resid(chi.sem) #residual sar
chi.poly@data$chi.sem.fval <- chi.sem$fitted.values

# grps <- 10
# brks <- quantile(resid(chi.ols), 0:(grps-1)/(grps-1), na.rm=TRUE)
# chi.poly@data$chi.ols.res<-resid(chi.ols) #residuals ols
# spplot(chi.poly,"chi.ols.res", at=brks,col.regions=spectral_col)


# brks <- quantile(resid(chi.sar), 0:(grps-1)/(grps-1), na.rm=TRUE)
# chi.poly@data$chi.sar.res<-resid(chi.sar) #residuals ols
# spplot(chi.poly,"chi.sar.res", at=brks,col.regions=spectral_col)
# 
# 
# brks <- quantile(resid(chi.sem), 0:(grps-1)/(grps-1), na.rm=TRUE)
# chi.poly@data$chi.sem.res<-resid(chi.sem) #residuals ols
# spplot(chi.poly,"chi.sem.res", at=brks,col.regions=spectral_col)

df_coord <- data.table(coordinates(chi.poly))
colnames(df_coord) <- c('lon', 'lat')
crime_dt <- data.table(chi.poly@data)
crime_dt <- cbind(crime_dt, df_coord)
crime_long = melt(crime_dt, measure.vars = c("chi.ols.res", "chi.sar.res", "chi.sem.res"))

chi.poly_f <- broom::tidy(chi.poly)

chi.poly$id <- row.names(chi.poly) # allocate an id variable to the sp data
head(chi.poly@data, n = 2) # final check before join (requires shared variable name)
chi.poly_f <- left_join(chi.poly_f, chi.poly@data) # join the data

chi_gam <- gam(violent ~ s(long, lat, bs='gp', k=100, m=2) + 
                 s(est_fcs_rt, k=5) + s(bls_unemp, k=3),
               data=chi.poly_f)
chi.poly_f <- setDT(chi.poly_f)
chi.poly_f <- chi.poly_f[, chi.gam.res := chi_gam$residuals]
chi.poly_f <- chi.poly_f[, chi.gam.fval := chi_gam$fitted.values]

chi.poly_f_long <- setDT(melt(chi.poly_f, measure.vars = 
                                c("chi.ols.res", "chi.sar.res", "chi.sem.res", "chi.gam.res",
                                  "chi.ols.fval", "chi.sar.fval", "chi.sem.fval", "chi.gam.fval")))
chi.poly_f_long <- chi.poly_f_long[, scaled_res := scale(value), by = .(variable)]

qcut = function(x, n) {
  quantiles = seq(0, 1, length.out = n+1)
  cutpoints = unname(quantile(x, quantiles, na.rm = TRUE))
  cut(x, cutpoints, include.lowest = TRUE)
}

chi.poly_f_long <- chi.poly_f_long[, res_quant := qcut(value, 10)]


map_p <- ggplot(data = chi.poly_f_long, # the input data
           aes(x = long, y = lat, fill = value, group = group)) + # define variables
              geom_polygon() + # plot the boroughs
              geom_path(colour="black", lwd=0.05) + # borough borders
              coord_equal() + # fixed x and y scales
              facet_wrap(~ variable, ncol = 4) + # one plot per time slice
              scale_fill_distiller(palette = "RdBu") + # legend options
              theme(axis.text = element_blank(), # change the theme options
                    axis.title = element_blank(), # remove axis titles
                    axis.ticks = element_blank()) # remove axis ticks


map_p


