#' An adaptation of the simulated annealing algorithm for psychometric models.
#'
#' @description Simulated annealing mimics the physical process of annealing metals together. [Kirkpatrick et al. (1983)](http://science.sciencemag.org/content/220/4598/671) introduces this analogy and demonstrates its use; the implementation here follows this demonstration closely, with some modifications to make it better suited for psychometric models.
#'
#' @details \strong{Outline of the Pieces of the Simulated Annealing Algorithm} 
#' * initialModel -- the initial, full form
#' * currentModel -- the model of the current step
#' * maxSteps -- the maximum number of steps (iterations)
#' * currentStep -- the current step
#' * currentTemp -- the current temperature. A function of the number of steps (such that temp = 0 at maxSteps), and values that control the shape of the overall temperature. A part of the function that determines the acceptance probability of newly -- generated models
#' * randomNeighbor -- a function that determines how the form is changed at each step. Should be able to change one or more parameters, and should have a way to control how many are changed.
#' * goal -- a function that determines the "goodness" of the currentModel. Typically in SA goodness is defined as minimization! Sometimes called an energy function
#' * selectionFunction -- a function that determines if a randomNeighbor change is accepted. Uses the goal function that determines the "goodness" of the currentModel and the "goodness" of the randomNeighbor, and the currentTemp to generate a probability of acceptance, then compares this probability to a Uniform(0,1) variable to determine if accepted or not. A standard version of this is:
#' ![](SA-goal.jpg) 
#' (Kirkpatrick et al., 1983)
#' * bestModel -- the model with the best value of the goal function achieved so far
#' * bestGoal -- the best value of the goal function achieved so far
#' * restartCriteria -- if utilized, this would "restart" the SA process by changing currentModel to bestModel and continuing the process. Could be based on (1) the currentStep value, (2) the difference between goal(currentModel) and goal(bestModel), (3) randomness (i.e., could randomly restart, could randomly restart based on some values, etc), (4) other critera.
#'
#' @param initialModel The initial model as a character vector with lavaan model.syntax.
#' @param originalData The original data frame with variable names.
#' @param maxSteps The number of iterations for which the algorithm will run.
#' @param fitStatistic Either a single model fit statistic produced by lavaan, or a user-defined fit statistic function.
#' @param temperature Either an acceptable character value, or a user-defined temperature function. The acceptable values are "linear", "quadratic", or "logistic".
#' @param maximize Logical indicating if the goal is to maximize (TRUE) the fitStatistic for model selection.
#' @param Kirkpatrick Either TRUE to use Kirkpatrick et al. (1983) acceptance probability, or a user-defined function for accepting proposed models.
#' @param randomNeighbor Either TRUE to use the included function for randomNeighbor selection, or a user-defined function for creating random models.
#' @param lavaan.model.specs A list which contains the specifications for the
#'  lavaan model. The default values are the defaults for lavaan to perform a
#'  CFA. See \link[lavaan]{lavaan} for more details.
#' @param maxChanges An integer value greater than 1 setting the maximum number of parameters to change within randomNeighbor. When creating a short form, should be no greater than the smallest reduction in items loading on one factor; e.g., when reducing a 2-factor scale from 10 items on each factor to 8 items on the first and 6 items on the second, maxChanges should be no greater than 2.
#' @param restartCriteria Either "consecutive" to restart after maxConsecutiveSelection times with the same model chosen in a row, or a user-defined function.
#' @param maximumConsecutive A numeric value used with restartCriteria.
#' @param maxItems When creating a short form, a vector of the number of items per factor you want the short form to contain. Defaults to `NULL`.
#' @param items A character vector of item names. Defaults to `NULL`. Ignored if `maxItems==FALSE`.
#' @param bifactor Logical. Indicates if the latent model is a bifactor model. If `TRUE`, assumes that the last latent variable in the provided model syntax is the bifactor (i.e., all of the retained items will be set to load on the last latent variable). Ignored if `maxItems==FALSE`.
#' @param progress Character. If `'bar'`, the function prints a progress bar indicating how far along it is. If `'text'`, prints the current step value. Otherwise, nothing is printed to indicate the progress of the function.
#' @param ... Further arguments to be passed to other functions. Not implemented for any of the included functions.
#'
#' @return A named list: the 'bestModel' found, the 'bestFit', and 'allFit' values found by the algorithm.
#'
#' @examples \dontrun{
#' data(exampleAntModel)
#' data(simulated_test_data)
#' trial1 <- simulatedAnnealing(initialModel = lavaan::cfa(model = exampleAntModel,
#'                                                         data = simulated_test_data),
#'                              originalData = simulated_test_data, maxSteps = 3,
#'                              fitStatistic = 'rmsea', maximize = FALSE)
#' # lavaan::summary(trial1[[1]]) # shows the resulting model
#'
#' trial2 <- simulatedAnnealing(initialModel = exampleAntModel,
#' originalData = simulated_test_data,
#' maxSteps = 2, maxItems = 30, items = paste0("Item", 1:56))
#' # lavaan::summary(trial2[[1]]) # shows the resulting model
#' }
#' @import lavaan utils
#' @export
#' @md

simulatedAnnealing <-
  function(initialModel,
           originalData,
           maxSteps,
           fitStatistic = 'cfi',
           temperature = "linear",
           maximize = TRUE,
           Kirkpatrick = TRUE,
           randomNeighbor = TRUE,
           lavaan.model.specs = list(
             model.type = "cfa",
             auto.var = TRUE,
             estimator = "default",
             ordered = NULL,
             int.ov.free = TRUE,
             int.lv.free = FALSE,
             std.lv = TRUE,
             auto.fix.first = FALSE,
             auto.fix.single = TRUE,
             auto.cov.lv.x = TRUE,
             auto.th = TRUE,
             auto.delta = TRUE,
             auto.cov.y = TRUE
           ),
           maxChanges = 5,
           restartCriteria = "consecutive",
           maximumConsecutive = 25,
           maxItems = NULL,
           items = NULL,
           bifactor = FALSE,
           progress = 'bar',
           ...) {
    #### initial values ####
    currentStep = 0
    consecutive = 0
    allFit = c()
    fitmeasuresCheck(fitStatistic)
    # creates objects in the function environment that are fed into the lavaan function in order to fine-tune the model to user specifications
    # solution from: https://stackoverflow.com/questions/6375790/r-creating-an-environment-in-the-globalenv-from-inside-a-function
    # makeCache <- function() {
    #   # list(get = function(key) cache[[key]],
    #   #      set = function(key, value) cache[[key]] <- value
    #   #      )
    # }
    checkModelSpecs(lavaan.model.specs)
    mapply(
      assign,
      names(lavaan.model.specs),
      lavaan.model.specs,
      MoreArgs = list(envir = environment())
    )
    
    if (!is.null(maxItems)) {
      # if using the short form option
      cat("Initializing short form creation.")
      mapply(
        assign,
        x = 'allItems',
        value = list(items),
        USE.NAMES = FALSE,
        SIMPLIFY = FALSE,
        MoreArgs = list(envir = environment())
      )
      randomInitialModel = function(init.model = initialModel,
                                    maxItems = numItems,
                                    initialData = originalData,
                                    bifactorModel = bifactor) {
        # extract the latent factor syntax
        mapply(
          assign,
          c("factors", "itemsPerFactor"),
          syntaxExtraction(initialModelSyntaxFile = initialModel, items = allItems),
          MoreArgs = list(envir = environment())
        )
        
        # save the external relationships
        vectorModel =  unlist(strsplit(x = initialModel, split = "\\n"))
        externalRelation = vectorModel[grep(" ~ ", vectorModel)]
        factorRelation = vectorModel[grep(" ~~ ", vectorModel)]
        
        # reduce the number of items for each factor according to maxItems
        newItemsPerFactor = list()
        for (i in 1:length(itemsPerFactor)) {
          newItemsPerFactor[[i]] = sample(x = unique(unlist(itemsPerFactor[i])), size = unlist(maxItems[i]))
        }
        
        if (bifactorModel == TRUE) {
          # if bifactorModel == TRUE, fix the items so the newItems all load on the bifactor
          # assumes that the bifactor latent variable is the last one
          newItemsPerFactor[[length(itemsPerFactor)]] = unlist(newItemsPerFactor[1:(length(itemsPerFactor) - 1)])
        }
        
        # create the new model syntax
        
        newModelSyntax = c()
        for (i in 1:length(factors)) {
          newModelSyntax[i] = paste(factors[i],
                                    "=~",
                                    paste(newItemsPerFactor[[i]], collapse = " + "))
        }
        newModelSyntax = c(newModelSyntax, externalRelation, factorRelation)
        
        # fit the new model
        newModel = modelWarningCheck(
          lavaan::lavaan(
            model = newModelSyntax,
            data = initialData,
            model.type = model.type,
            int.ov.free = int.ov.free,
            int.lv.free = int.lv.free,
            auto.fix.first = auto.fix.first,
            std.lv = std.lv,
            auto.fix.single = auto.fix.single,
            auto.var = auto.var,
            auto.cov.lv.x = auto.cov.lv.x,
            auto.th = auto.th,
            auto.delta = auto.delta,
            auto.cov.y = auto.cov.y,
            ordered = ordered,
            estimator = estimator,
          )
        )
        newModel$model.syntax = newModelSyntax
        
        return(newModel)
      }
      currentModel = bestModel = randomInitialModel(initialModel,
                                                    maxItems,
                                                    initialData = originalData,
                                                    bifactorModel = bifactor)
      cat(paste(
        "\nThe initial short form is:\n",
        paste(currentModel$model.syntax, collapse = "\n")
      ))
      bestFit = tryCatch(
        lavaan::fitmeasures(object = bestModel[[1]], fit.measures = fitStatistic),
        error = function(e, checkMaximize = maximize) {
          if (length(e) > 0) {
            if (checkMaximize == TRUE) {
              return(0)
            } else {
              return(Inf)
            }
          }
        }
      )
      if (is.null(items)) {
        stop(
          "To use this function for short forms, you need to set both the maxItems to consider as well as the names of the items."
        )
      }
      
      cat("\nUsing the short form randomNeighbor function.")
      cat("\nFinished initializing short form options.")
    } else {
      # if not using the short form option
      bestFit = tryCatch(
        lavaan::fitmeasures(object = bestModel, fit.measures = fitStatistic),
        error = function(e, checkMaximize = maximize) {
          if (length(e) > 0) {
            if (checkMaximize == TRUE) {
              return(0)
            } else {
              return(Inf)
            }
          }
        }
      )
      currentModel <- 
        list('lavaan.output' = initialModel,
             'warnings' = NULL,
             'errors' = NULL
             )
      randomNeighborFull <-
        function(currentModelObject = currentModel,
                 numChanges = numChanges,
                 data) {
          if (class(currentModelObject) == "list") {
            currentModelObject = currentModelObject[[1]]
          }
          
          # using lavaan functions, construct a full parameter table
          paramTable <- lavaan::parTable(currentModelObject)
          # fullParamTable <- lavaan:::lav_partable_full(paramTable)
          # currentModelParams <- lavaan::lav_partable_merge(paramTable, fullParamTable, remove.duplicated = TRUE, warn = FALSE)
          
          # select the rows that correspond to parameters related to the latent variables
          latentVariables <-
            row.names(lavaan::inspect(currentModelObject, "cor.lv"))
          currentModelParamsLV <-
            paramTable[paramTable$lhs %in% latentVariables, ]
          
          # randomly select rows to make changes to
          randomChangesRows <-
            sample(currentModelParamsLV$id, size = numChanges)
          changeParamTable <- paramTable[randomChangesRows, ]
          
          # make the changes. If currently free, fix to 0; if fixed to 0, set to free
          paramTable$free[randomChangesRows] <-
            1 - paramTable$free[randomChangesRows]
          
          # remove the starting value, estimates, and standard errors of the currentModel
          paramTable$est <- NULL
          paramTable$se <- NULL
          paramTable$start <- NULL
          paramTable$labels <- NULL
          
          # refit the model
          prevModel <- as.list(currentModelObject@call)
          prevModel$model <- paramTable
          # randomNeighborModel <- try(do.call(eval(parse(text = "lavaan::lavaan")), prevModel[-1]), silent = TRUE)
          
          randomNeighborModel <-
            modelWarningCheck(lavaan::lavaan(model = prevModel$model,
                                             data = data))
          
          return(randomNeighborModel)
        }
    }
    
    
    #### selecting functions for use in algorithm ####
    if (temperature == "linear") {
      temperatureFunction <- linearTemperature
    } else if (temperature == "quadratic") {
      temperatureFunction <- quadraticTemperature
    } else if (temperature == "logistic") {
      temperatureFunction <- logisticTemperature
    } else if (class(temperature == "function")) {
      temperatureFunction <- temperature
    } else {
      stop(
        "You need to specify an appropriate default temperature (one of \"linear\", \"quadratic\", or \"logistic\") or include a temperature in the form of a function to continue."
      )
    }

    if (class(restartCriteria) == "function") {
      restartCriteria = restartCriteria
    } else if (restartCriteria == "consecutive") {
      restartCriteria <- consecutiveRestart
    } else {
      restartCriteria = function() {
        
      }
      warning(
        "The restart criteria should to be either \"consecutive\" (the default) or a custom function. It has been set to NULL so the algorithm will not restart at all."
      )
    }
    #### perform algorithm ####
    
    cat("\n Current Progress:")
    if (progress == 'bar') {
      trackStep = txtProgressBar(
        min = 0,
        max = maxSteps - 1,
        initial = 1,
        style = 3
      )
    }
    
    
    while (currentStep < maxSteps) {
      if (progress == 'bar') {
        setTxtProgressBar(trackStep, currentStep)
      } else if (progress == 'text') {
        cat(paste0(
          "\r Current Step = ",
          currentStep,
          " of a maximum ",
          maxSteps,
          ".  "
        ))
      }
      # how many changes to make?
      numChanges = sample(1:maxChanges, size = 1)
      # generate random model
      if (is.null(maxItems) & randomNeighbor == TRUE) {
        randomNeighborModel = randomNeighborFull(
          currentModelObject = currentModel,
          numChanges = numChanges,
          data = originalData
        )
      } else if (randomNeighbor == TRUE) {
        randomNeighborModel = randomNeighborShort(
          currentModelObject = currentModel,
          numChanges = numChanges,
          data = originalData,
          allItems = allItems,
          bifactor = bifactor,
          init.model = initialModel,
          lavaan.model.specs = lavaan.model.specs
        )
        
      }
      # select between random model and current model
      currentModel = selectionFunction(
        currentModelObject = currentModel,
        randomNeighborModel = randomNeighborModel,
        currentTemp = temperatureFunction(currentStep, maxSteps),
        maximize = maximize,
        fitStatistic = fitStatistic,
        consecutive = consecutive
      )
      # recored fit
      allFit[currentStep + 1] =  tryCatch(
        lavaan::fitmeasures(object = currentModel[[1]], fit.measures = fitStatistic),
        error = function(e) {
          if (length(e) > 0) {
            bestFit
          }
        }
      )
      # check for current best model
      bestModel = checkModels(currentModel, fitStatistic, maximize, bestFit, bestModel)
      bestFit = tryCatch(
        lavaan::fitmeasures(object = bestModel, fit.measures = fitStatistic),
        error = function(e) {
          if (length(e) > 0) {
            bestFit
          }
        }
      )
      # restart if the same model was chosen too many times
      restartCriteria(maxConsecutiveSelection = maximumConsecutive,
                      consecutive = consecutive)
      currentStep = currentStep + 1
    }
    
    results = list(
      bestModel = bestModel,
      bestFit = bestFit,
      allFit = allFit,
      bestSyntax = currentModel$model.syntax
    )
    class(results) = "simulatedAnnealing"
    return(results)
  }
