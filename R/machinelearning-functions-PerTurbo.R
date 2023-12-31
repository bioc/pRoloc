##' Classification parameter optimisation for the PerTurbo algorithm
##'
##' Note that when performance scores precision, recall and (macro) F1
##' are calculated, any NA values are replaced by 0. This decision is
##' motivated by the fact that any class that would have either a NA
##' precision or recall would result in an NA F1 score and,
##' eventually, a NA macro F1 (i.e. mean(F1)). Replacing NAs by 0s
##' leads to F1 values of 0 and a reduced yet defined final macro F1
##' score.
##' 
##' @title PerTurbo parameter optimisation
##' @param object An instance of class \code{"\linkS4class{MSnSet}"}.
##' @param fcol The feature meta-data containing marker definitions.
##' Default is \code{markers}.
##' @param inv The type of algorithm used to invert the matrix.
##' Values are :
##' "Inversion Cholesky" (\code{\link{chol2inv}}),
##' "Moore Penrose" (\code{\link{ginv}}),
##' "solve" (\code{\link{solve}}),
##' "svd" (\code{\link{svd}}).
##' Default value is \code{"Inversion Cholesky"}.
##' @param reg The type of regularisation of matrix.
##' Values are "none", "trunc" or "tikhonov".
##' Default value is \code{"tikhonov"}.
##' @param pRegul The hyper-parameter for the regularisation (values are in ]0,1] ).
##' If reg =="trunc", pRegul is for the percentage of eigen values in matrix.
##' If reg =="tikhonov", then 'pRegul' is the parameter for the tikhonov regularisation.
##' Available configurations are :
##' "Inversion Cholesky" - ("tikhonov" / "none"),
##' "Moore Penrose" - ("tikhonov" / "none"),
##' "solve" - ("tikhonov" / "none"),
##' "svd" - ("tikhonov" / "none" / "trunc").
##' @param sigma The hyper-parameter.
##' @param times The number of times internal cross-validation is performed.
##' Default is 100.
##' @param test.size The size of test data. Default is 0.2 (20 percent).
##' @param xval The \code{n}-cross validation. Default is 5.
##' @param fun The function used to summarise the \code{times} macro F1 matrices.
##' @param seed The optional random number generator seed.
##' @param verbose A \code{logical} defining whether a progress bar is displayed.
##' @return An instance of class \code{"\linkS4class{GenRegRes}"}.
##' @seealso \code{\link{perTurboClassification}} and example therein.
##' @aliases perTurboOptimization 
##' @author Thomas Burger and Samuel Wieczorek
perTurboOptimisation <- function(object,
                                 fcol = "markers",
                                 pRegul = 10^(seq(from=-1,to=0,by=0.2)), 
                                 sigma = 10^(seq(from=-1,to=1,by=0.5)),
                                 inv = c("Inversion Cholesky",
                                   "Moore Penrose",
                                   "solve", "svd"),
                                 reg = c("tikhonov", "none", "trunc"),
                                 times = 1,
                                 test.size = .2,
                                 xval = 5,                               
                                 fun = mean,
                                 seed,
                                 verbose = TRUE ) {
  inv <- match.arg(inv)
  reg <- match.arg(reg)
  nparams <- 2 ## 2 or 1, depending on the algorithm
  mydata <- subsetAsDataFrame(object, fcol, train = TRUE)
  if (reg == "none") {
    if (verbose) {
      message("Setting 'pRegul' to 1 when using 'reg' == 'none'")
      pRegul <- 1
    }
  }
    
  ## Check whether the method of inversion 'inv'
  ## with the regularisation methode 'reg' is implemented
  test <- controlParameters(inv, reg)
  .inv <- test$inv
  .reg <- test$reg

  if (missing(seed)){
    seed <- sample(.Machine$integer.max,1)
  }
  .seed <- as.integer(seed)
  set.seed(.seed)
  
  ## initialise output
  .warnings <- NULL
  .f1Matrices <- vector("list", length = times)
  .testPartitions <- .cmMatrices <- vector("list", length = times) ## NEW
  .results <- matrix(NA, nrow = times, ncol = nparams + 1)
  colnames(.results) <- c("F1", "sigma", "pRegul") 
  
  if (verbose) {
    pb <- txtProgressBar(min = 0,
                         max = xval * times,
                         style = 3)
    ._k <- 0
  }
  for (.times in 1:times) {
    .size <- ceiling(table(mydata$markers) * test.size)
    ## size is ordered according to levels, but strata
    ## expects them to be ordered as they appear in the data
    .size <- .size[unique(mydata$markers)] 
    test.idx <- sampling::strata(mydata, "markers",
                                 size = .size,
                                 method = "srswor")$ID_unit
    .testPartitions[[.times]] <- test.idx ## NEW
    
    .test1   <- mydata[ test.idx, ] ## 'unseen' test set
    .train1  <- mydata[-test.idx, ] ## to be used for parameter optimisation
    
    .train1Sep <- separateDataSet(.train1, fcol)
    .test1Sep <- separateDataSet(.test1, fcol)
    
    
    xfolds <- createFolds(.train1Sep$theLabels, xval, returnTrain = TRUE)
    ## stores the xval F1 matrices
    .matrixF1L <- vector("list", length = xval)  
    
    for (.xval in 1:xval) {    
      if (verbose) {
        setTxtProgressBar(pb, ._k)
        ._k <- ._k + 1
      }
      .train2 <- .train1[ xfolds[[.xval]], ]
      .test2  <- .train1[-xfolds[[.xval]], ]    
      
      .train2Sep <- separateDataSet(.train2, fcol)
      .test2Sep <- separateDataSet(.test2, fcol)
      
      ## The second argument in makeF1matrix will be
      ## used as rows, the first one for columns
      .matrixF1 <- makeF1matrix(list(pRegul = pRegul, sigma = sigma))
      ## grid search for parameter selection
      for (.pRegul in pRegul) {
        for (.sigma in sigma) {
          .model <- trainingPerTurbo(.train2Sep$theLabels, .train2Sep$theData, .sigma, .inv, .reg, .pRegul )
          ans <- testPerTurbo(.model, .test2Sep$theLabels, .test2Sep$theData)
          conf <- confusionMatrix(ans, .test2Sep$theLabels)$table
          .p <- checkNumbers(MLInterfaces:::.precision(conf))
          .r <- checkNumbers(MLInterfaces:::.recall(conf))
          .f1 <- MLInterfaces:::.macroF1(.p, .r, naAs0 = TRUE)
          .matrixF1[as.character(.sigma), as.character(.pRegul)] <- .f1
        } # END for (.pRegul in pRegul)
      } # END for (.sigma in sigma)
      
      ## we have a complete grid to be saved
      .matrixF1L[[.xval]] <- .matrixF1
    }
    
    ## we have xval grids to be summerised
    .summaryF1 <- summariseMatList(.matrixF1L, fun)
    .f1Matrices[[.times]] <- .summaryF1
    .bestParams <- getBestParams(.summaryF1)[1:nparams, 1] ## takes a random best param
    
    .model <- trainingPerTurbo(.train1Sep$theLabels,
                               .train1Sep$theData,
                               sigma = .bestParams["sigma"],
                               .inv, .reg, pRegul = .bestParams["pRegul"])
    ans <- testPerTurbo(.model, .test2Sep$theLabels, .test2Sep$theData)
    
    conf <- confusionMatrix(ans, .test2Sep$theLabels)$table
    p <- checkNumbers(MLInterfaces:::.precision(conf),
                      tag = "precision", params = .bestParams)
    r <- checkNumbers(MLInterfaces:::.recall(conf),
                      tag = "recall", params = .bestParams)
    f1 <- MLInterfaces:::.macroF1(p, r, naAs0 = TRUE) ## macro F1 score for .time's iteration
    .results[.times, ] <- c(f1, .bestParams["sigma"], .bestParams["pRegul"])
  }
  if (verbose) {
    setTxtProgressBar(pb, ._k)
    close(pb)
  }
  
  .hyperparams <- list(pRegul = pRegul,
                       sigma = sigma)    
  .hyperparams$other <- c("inv" = inv, "reg" = reg)
  ## .hyperparams should probably also store inv and reg.
  
  .design <- c(xval = xval,
               test.size = test.size,
               times = times)

  ans <- new("GenRegRes",
             algorithm = "perTurbo",
             seed = .seed,
             hyperparameters = .hyperparams,
             design = .design,
             results = .results,
             f1Matrices = .f1Matrices,
             cmMatrices = .cmMatrices, ## NEW
             testPartitions = .testPartitions, ## NEW
             datasize = list(
               "data" = dim(mydata),
               "data.markers" = table(mydata[, "markers"]),
               "train1" = dim(.train1),
               "test1" = dim(.test1),
               "train1.markers" = table(.train1[, "markers"]),
               "train2" = dim(.train2),
               "test2" = dim(.test2),
               "train2.markers" = table(.train2[, "markers"])))

  if (!is.null(.warnings)) {
    ans@log <- list(warnings = .warnings)
    sapply(.warnings, warning)
  }
  return(ans)
}

perTurboOptimization <- 
  perTurboOptimisation

##' Classification using the PerTurbo algorithm.
##'
##' @title perTurbo classification
##' @param object An instance of class \code{"\linkS4class{MSnSet}"}.
##' @param assessRes An instance of class
##'     \code{"\linkS4class{GenRegRes}"}, as generated by
##'     \code{\link{svmRegularisation}}.
##' @param scores One of \code{"prediction"}, \code{"all"} or
##'     \code{"none"} to report the score for the predicted class
##'     only, for all classes or none.
##' @param pRegul If \code{assessRes} is missing, a \code{pRegul} must
##'     be provided.  See \code{\link{perTurboOptimisation}} for
##'     details.
##' @param sigma If \code{assessRes} is missing, a \code{sigma} must
##'     be provided.  See \code{\link{perTurboOptimisation}} for
##'     details.
##' @param inv The type of algorithm used to invert the matrix.
##'     Values are : "Inversion Cholesky" (\code{\link{chol2inv}}),
##'     "Moore Penrose" (\code{\link{ginv}}), "solve"
##'     (\code{\link{solve}}), "svd" (\code{\link{svd}}).  Default
##'     value is \code{"Inversion Cholesky"}.
##' @param reg The type of regularisation of matrix.  Values are
##'     "none", "trunc" or "tikhonov".  Default value is
##'     \code{"tikhonov"}.
##' @param fcol The feature meta-data containing marker definitions.
##'     Default is \code{markers}.
##' @return An instance of class \code{"\linkS4class{MSnSet}"} with
##'     \code{perTurbo} and \code{perTurbo.scores} feature variables
##'     storing the classification results and scores respectively.
##' @references N. Courty, T. Burger,
##'     J. Laurent. "PerTurbo: a new classification algorithm based on the spectrum perturbations of the Laplace-Beltrami operator",
##'     The European Conference on Machine Learning and Principles and
##'     Practice of Knowledge Discovery in Databases (ECML-PKDD 2011),
##'     D. Gunopulos et al.  (Eds.): ECML PKDD 2011, Part I, LNAI
##'     6911, pp. 359 - 374, Athens, Greece, September 2011.
##' @author Thomas Burger and Samuel Wieczorek
##' @examples
##' library(pRolocdata)
##' data(dunkley2006)
##' ## reducing parameter search space 
##' params <- perTurboOptimisation(dunkley2006,
##'                                pRegul = 2^seq(-2,2,2),
##'                                sigma = 10^seq(-1, 1, 1),
##'                                inv = "Inversion Cholesky",
##'                                reg ="tikhonov",
##'                                times = 3)
##' params
##' plot(params)
##' f1Count(params)
##' levelPlot(params)
##' getParams(params)
##' res <- perTurboClassification(dunkley2006, params)
##' getPredictions(res, fcol = "perTurbo")
##' getPredictions(res, fcol = "perTurbo", t = 0.75)
##' plot2D(res, fcol = "perTurbo")
perTurboClassification <- function(object,                            
                                   assessRes,
                                   scores = c("prediction", "all", "none"),
                                   pRegul,  
                                   sigma,
                                   inv,
                                   reg,
                                   fcol = "markers") {
  scores <- match.arg(scores)
  if (missing(assessRes)) {
    if (missing(pRegul) | missing(sigma) | missing(inv) | missing(reg))
      stop("First run 'perTurboRegularisation' or set 'pRegul', 'sigma', 'inv' and 'reg' manually.")
    params <- c("pRegul" = pRegul,
                "sigma" = sigma)
    inv <- match.arg(inv,
                     choices = c("Inversion Cholesky",
                       "Moore Penrose",
                       "solve", "svd"))
    reg <- match.arg(reg,
                     choices = c("tikhonov",
                       "none", "trunc"))
    ## Check whether the method of inversion 'inv'
    ## with the regularisation method 'reg' is implemented
    test <- controlParameters(inv, reg)
    .inv <- test$inv
    .reg <- test$reg
  } else {
    params <- getParams(assessRes)
    if (is.na(params["pRegul"]))
      stop("No 'pRegul' found.")
    if (is.na(params["sigma"]))
      stop("No 'sigma' found.")

    ## Here, we assume correct parameters are passed,
    ## and do not call controlParameters, as they
    ## have been explicitly tested in perTurboOptimisation
    otherParams <- getOtherParams(assessRes)
    if (is.na(otherParams["inv"]))
      stop("No 'inv' found.")
    if (is.na(otherParams["reg"]))
      stop("No 'reg' found.")
    .inv <- otherParams["inv"]
    .reg <- otherParams["reg"]

  }
  
  trainInd <- which(fData(object)[, fcol] != "unknown")
  testInd <- which(fData(object)[, fcol] == "unknown")
  trainSet <- subsetAsDataFrame(object, fcol, train = TRUE)
  testSet <- subsetAsDataFrame(object, fcol, train = FALSE)
  
  .trainSep <- separateDataSet(trainSet, fcol)
  .testSep <- separateDataSet(testSet, fcol)
  
  
  .model <- trainingPerTurbo(.trainSep$theLabels, .trainSep$theData,
                             params["sigma"],
                             .inv,
                             .reg,
                             params["pRegul"])
  ans <- predictionPerTurbo(.model, .testSep$theLabels, .testSep$theData)
  
  temp <- rep("", length(trainInd) + length(testInd))
  ## Add known labels (i.e. training data)
  i <- 1:length(trainInd)
  temp[trainInd[i]] <- as.character(.trainSep$theLabels[i])
  
  ## Add predicted labels
  labels <- levels(.trainSep$theLabels)
  predictedLabels <- labels[apply(ans, 1, which.max)]
  i <- 1:length(testInd)
  temp[testInd[i]] <- as.character(predictedLabels[i])
  fData(object)$perTurbo <- temp  
  
  ## Would be better to check if these columns exist
  if (scores == "all") {
    nbLabels <- length(levels(.trainSep$theLabels))
    tempScores <- matrix(rep(0, nbLabels*(length(trainInd)+length(testInd))),
                         ncol = nbLabels)
    
    ## Add scores of training data 
    i <- 1:length(trainInd)
    tempScores[trainInd[i], ] <- rep(1,nbLabels)
    ## Add predicted labels
    i <- 1:length(testInd)
    tempScores[testInd[i],] <- ans[i,]
    
    colnames(tempScores) <- levels(.trainSep$theLabels)
    scoreMat <- tempScores
    colnames(scoreMat) <- paste0(colnames(scoreMat),
                                 ".perTurbo.scores")
    fData(object)$perTurbe.all.scores <- scoreMat
  } else if (scores == "prediction") {
    nbLabels <- length(levels(.trainSep$theLabels))
    tempScores <- rep(0,length(trainInd) + length(testInd))
    
    ## Add scores of training data
    i <- 1:length(trainInd)
    tempScores[trainInd[i]] <- 1
    ## Add predicted labels
    i <- 1:length(testInd)
    tempScores[testInd[i]] <- apply(ans, 1, max)
    fData(object)$perTurbo.scores <- tempScores    
  } ## else scores is "none"
  
  object@processingData@processing <-
    c(processingData(object)@processing,
      paste0("Performed perTurbo prediction (", 
             paste(paste(names(params), params, sep = "="),
                   collapse = " "), ") ",
             date()))
 
  if (validObject(object))
    return(object)
}
