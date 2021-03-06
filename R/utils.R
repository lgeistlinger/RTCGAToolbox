#' @importFrom GenomicRanges makeGRangesListFromDataFrame
#' @importFrom SummarizedExperiment SummarizedExperiment
#' @importFrom S4Vectors SimpleList metadata metadata<- DataFrame
#' @importFrom utils type.convert
#' @importFrom methods .hasSlot
## Helper functions for data extraction
.getDataMatrix <- function(object) {
    getElement(object, "DataMatrix")
}

.getFilenames <- function(object) {
    getElement(object, "Filename")
}

## Standardize barcode format
.stdIDs <- function(sampleBarcode) {
    bcodeTest <- grepl("\\.", sample(sampleBarcode, 10L, replace = TRUE))
    if (all(bcodeTest))
        sampleBarcode <- gsub("\\.", "-", sampleBarcode)
    toupper(sampleBarcode)
}

.standardizeBC <- function(x) {
    colnames(x) <- .stdIDs(colnames(x))
    return(x)
}

.getGISTIC <- function(x, type) {
    x <- getElement(x, type)
    annoteCols <- !grepl("TCGA", names(x))
    annoteRowDF <- x[, annoteCols]
    rownames(annoteRowDF) <-
        annoteRowDF[, grepl("gene", names(annoteRowDF), ignore.case = TRUE)]
    x <- x[, !annoteCols]
    x <- vapply(x, type.convert, numeric(nrow(x)))
    x <- .standardizeBC(x)
    SummarizedExperiment(SimpleList(x), rowData = annoteRowDF)
}

.getMethyl <- function(x) {
    headers <- names(x)
    annote <- x[, !grepl("TCGA", headers)]
    isNumRow <- all(grepl("^[0-9]*$",
                          sample(rownames(x), size = 100L, replace = TRUE)))
    if (isNumRow) {
        geneSymbols <- annote[, grep("symbol", names(annote),
                                     ignore.case = TRUE, value = TRUE)]
        rNames <- geneSymbols
    } else { rNames <- rownames(x) }
    dm <- data.matrix(x[, grepl("TCGA", names(x))])
    rownames(dm) <- rNames
    dm <- .standardizeBC(dm)
    SummarizedExperiment::SummarizedExperiment(SimpleList(dm), rowData = annote)
}

.removeShell <- function(x, type) {
    dataTypes <- c("clinical", "RNASeqGene", "miRNASeqGene", "RNASeq2GeneNorm",
        "CNASNP", "CNVSNP", "CNASeq", "CNACGH", "Methylation", "Mutation",
        "mRNAArray", "miRNAArray", "RPPAArray", "GISTIC", "GISTICA", "GISTICT")
    type <- match.arg(type, dataTypes)
    type <- gsub("A$|T$", "", type)
    x <- getElement(x, type)
    return(x)
}

.getHGBuild <- function(hgbuild) {
    buildDF <- DataFrame(Date = c("July 2004", "May 2004", "March 2006",
                                  "February 2009"),
                         NCBI = c("34", "35", "36", "37"),
                         UCSC = c("hg16", "hg17", "hg18", "hg19"))
    buildIndex <- match(hgbuild, buildDF[["NCBI"]])
    if (is.na(buildIndex)) {
        warning("build could not be matched")
        return(NA_character_)
    } else {
        ucscBuild <- buildDF$UCSC[buildIndex]
        return(ucscBuild)
    }
}

.searchBuild <- function(x) {
    gsub("(^.+)_(hg[0-9]{2})_(.+$)", "\\2", x = x, ignore.case = TRUE)
}

.nameClean <- function(x) {
    x <- gsub("human|hum|agilent", "", x)
    x <- gsub("transcriptome", "tx", x, ignore.case = TRUE)
    x <- gsub("methylation", "methyl", x, ignore.case = TRUE)
    x
}

.mergeNames <- function(platform, version) {
    plat <- Filter(function(x) { !is.na(x) && length(x) }, tolower(platform))
    plat <- plat[which.min(nchar(plat))]
    if (!length(version))
        return(plat)
    ver <- tolower(version)
    logRM <- ver %in% plat
    version <- version[!logRM]
    relNames <- c(plat, version)
    if (length(plat) > 1L) {
        warning("Multiple platform names found, taking first one")
        plat <- plat[[1L]]
    }
    if (length(plat) && any(grepl(plat, tolower(version)))) {
        keep <- grepl("[0-9]{2}$", relNames, ignore.case = TRUE)
        result <- relNames[keep]
    } else if (length(version) > 1L) {
        result <- paste(toupper(plat), paste0(version, collapse = "_"),
                        sep = "_")
    } else if (length(version)) {
        result <- paste(toupper(plat), version, sep = "_")
    } else {
        result <- ""
    }
    return(result)
}

.searchPlatform <- function(x) {
    brokenUP <- unlist(strsplit(x, "_"))
    brokenUP <- Filter(function(y) nchar(y) != 0L, brokenUP)
    platNumExp <- "[0-9]k$|[0-9]a$|450$|27$|ht|hg"
    namePlat <- unique(grep("cgh|mirna|meth|huex|^trans", brokenUP,
                            ignore.case = TRUE, value = TRUE))
    namePlat <- .nameClean(namePlat)
    vers <- grep(platNumExp, brokenUP, ignore.case = TRUE, value = TRUE)
    vers <- .nameClean(vers)
    result <- .mergeNames(namePlat, vers)
    return(result)
}

.unNestList <- function(x) {
    suppclasses <- all(vapply(x, function(y) {
        any(is(y, "FirehosemRNAArray"), is(y, "FirehoseCGHArray"),
            is(y, "FirehoseMethylationArray")) },
        logical(1L)))
    if (suppclasses) {
        x <- lapply(x, function(y) {
            fname <- .getFilenames(y)
            platform <- .searchPlatform(fname)
            if (!.hasBuildInfo(y))
                build <- .searchBuild(fname)
            y <- .getDataMatrix(y)
            y <- DataFrame(y)
            metadata(y) <- list(filename = fname, build = build,
                                platform = platform)
            return(y)
        })
        if (length(x) > 1L) {
            platNames <- vapply(x, function(y) {
                metadata(y)[["platform"]] }, character(1L))
            platNames <- gsub("human|hum|agilent", "", platNames)
            names(x) <- make.unique(platNames, sep = "_")
        } else if (length(x) == 1L) { x <- x[[1L]] }
    }
    return(x)
}

.fileSelect <- function() {
    g <- readline(
        paste0("The selected data type has more than one",
               "file available.\nPlease select the desired file.",
               "\n(Enter 0 for the first file with the most number of samples)\n_"))
    g <- suppressWarnings(as.integer(g))
    if(is.na(g)){
        stop("Your selection must be an integer!")
    } else {
        return(g)
    }
}

.findCol <- function(x, colname) {
    stopifnot(is.character(colname))
    dataNames <- tolower(gsub("\\.|_", "", names(x)))
    colname <- tolower(gsub("\\.|_", "", colname))
    foundInData <- dataNames %in% colname
    if (sum(foundInData) > 1L)
        stop("Multiple matched columns detected")
    names(x)[foundInData]
}

.hasBuildInfo <- function(x) {
    buildInfo <- .findCol(x, "NCBI_Build")
    as.logical(length(buildInfo))
}

.hasHugoInfo <- function(x) {
    hugoInfo <- .findCol(x, "Hugo_Symbol")
    as.logical(length(hugoInfo))
}

.getBuild <- function(x) {
    binf <- .hasBuildInfo(x)
    if (binf) {
        BCOL <- .findCol(x, "NCBI_Build")
        build <- unique(x[[BCOL]])
        if (length(build) > 1L)
            stop("Inconsistent genome build column")
        build <- as.character(build)
        return(.getHGBuild(build))
    } else {
        stop("Build not available")
    }
}

.ansRangeNames <- function(x) {
    if (is(x, "list")) { return(list()) }
    granges_cols <- findGRangesCols(names(x), seqnames.field = "Chromosome",
                                    start.field = c("Start", "Start_position"),
                                    end.field = c("End", "End_position"))
    fielders <- list(seqnames.field = "seqnames", start.field = "start",
                     end.field = "end", strand.field = "strand")
    Fargs <- lapply(fielders, function(name) { names(x)[granges_cols[[name]]] })
    Fargs[["ignore.strand"]] <- is.na(Fargs[["strand.field"]])
    Filter(function(g) {!is.na(g)}, Fargs)
}

.findSampleCol <- function(x) {
    tsb <- match("tumor_sample_barcode", tolower(names(x)))
    if (length(tsb) == 1L && !is.na(tsb)) {
        primary <- names(x)[tsb]
    } else if (is.na(tsb)) {
        primary <- names(x)[tolower(names(x)) == "sample"]
    } else {
        stop("'split.field' could not be found")
    }
    return(primary)
}

.hasConsistentRanges <- function(object) {
    primary <- .findSampleCol(object)
    if (is(object, "DataFrame"))
        asListData <- IRanges::splitAsList(object, object[[primary]])
    else
        asListData <- base::split(object, object[[primary]])
    S4Vectors::isSingleInteger(unique( vapply(asListData, nrow, integer(1L)) ))
}

.hasRangeNames <- function(x) {
    if (is(x, "list")) { return(FALSE) }
    if (all(grepl("^TCGA", names(x)))) { return(FALSE) }
    if (!any(is.data.frame(x), is(x, "DataFrame"), is.matrix(x)))
        stop("(internal) 'x' must be rectangular")
    !all(is.na(findGRangesCols(names(x), seqnames.field = "Chromosome",
                               start.field = c("Start", "Start_position"),
                               end.field = c("End", "End_position"))))
}

## Safe to assume equal number of ranges == equal ranges (?)

.makeRangedSummarizedExperimentFromDataFrame <- function(df, ...,
                                                         seqinfo = NULL, starts.in.df.are.0based = FALSE) {
    args <- list(...)
    if (!is.null(args[["build"]]))
        GBuild <- args[["build"]]
    metadat <- metadata(df)
    if (!.hasConsistentRanges(df))
        stop("All ranges must be equal in number by 'split.field'")
    split.field <- .findSampleCol(df)
    ansRanges <- .ansRangeNames(df)
    strictRanges <- Filter(function(x) !is.logical(x), ansRanges)
    RangeInfo <- c(strictRanges, list(split.field = split.field))
    numInfo <- df[, !(names(df) %in% RangeInfo)]
    numAssays <- ncol(numInfo)
    nameAssays <- names(numInfo)
    if (is(df, "DataFrame"))
        numInfo <- IRanges::splitAsList(numInfo, df[[split.field]])
    else
        numInfo <- base::split(numInfo, df[[split.field]])
    countList <- vector(mode = "list", length = numAssays)
    for (i in seq_len(numAssays)) {
        countList[[i]] <- do.call(cbind, lapply(numInfo,
                                                function(smalldf) { smalldf[[i]] }))
    }
    names(countList) <- nameAssays
    rowRanges <- makeGRangesListFromDataFrame(df[, unlist(RangeInfo)],
                                              split.field = split.field)
    if (exists("GBuild"))
        GenomeInfoDb::genome(rowRanges) <- GBuild
    newSE <- SummarizedExperiment(assays = SimpleList(countList),
                                  rowRanges = rowRanges)
    metadata(newSE) <- metadat
    return(newSE)
}

.makeRaggedExperimentFromDataFrame <- function(df, ...) {
    args <- list(...)
    if (!is.null(args[["build"]]))
        GBuild <- args[["build"]]
    metadat <- if (is(df, "DataFrame")) { metadata(df) } else { list() }
    split.field <- .findSampleCol(df)
    ansRanges <- .ansRangeNames(df)
    rangeInfo <- c(ansRanges, list(split.field = split.field))
    dropIdx <- .omitAdditionalIdx(df, ansRanges)
    if (length(dropIdx))
        df <- df[, -dropIdx]
    if (.hasHugoInfo(df)) {
        hugos <- df[, .findCol(df, "Hugo_Symbol")]
        if (identical(length(hugos), length(unique(hugos))))
            rownames(df) <- df[, .findCol(df, "Hugo_Symbol")]
    }
    newGRL <- do.call(makeGRangesListFromDataFrame,
                      args = c(list(df = df, keep.extra.columns = TRUE), rangeInfo))
    if (exists("GBuild"))
        GenomeInfoDb::genome(newGRL) <- GBuild
    newRE <- RaggedExperiment::RaggedExperiment(newGRL)
    metadata(newRE) <- metadat
    return(newRE)
}

.omitAdditionalIdx <- function(object, rangeNames) {
    rangeNames <- Filter(function(x) !is.logical(x), rangeNames)
    rangeIdx <- match(rangeNames, names(object))
    omitAdditional <- c("seqnames", "seqname", "chromosome", "chrom",
                        "chromosome_name", "ranges", "seqlevels", "seqlengths", "seq_id",
                        "iscircular", "start", "end", "strand", "width", "element", "chr")
    rmIdx <- which(tolower(names(object)) %in% omitAdditional)
    setdiff(rmIdx, rangeIdx)
}

## Genome build from FILENAME
## RSE helper function from genome symbols to build (RNASeq, ExpSets)

.extractList <- function(object, type) {
    for (i in seq_along(object))
        object[[i]] <- biocExtract(object[[i]], type)
    return(object)
}

## Helper functions
.find_start_end_cols <- function (df_colnames, start.field, end.field) {
    idx1 <- which(df_colnames %in% start.field)
    idx2 <- which(df_colnames %in% end.field)
    prefixes1 <- .collect_prefixes(df_colnames, start.field)
    prefixes2 <- .collect_prefixes(df_colnames, end.field)
    suffixes1 <- .collect_suffixes(df_colnames, start.field)
    suffixes2 <- .collect_suffixes(df_colnames, end.field)
    if (length(idx1) != 1L || length(idx2) != 1L) {
        matchPre <- intersect(prefixes1, prefixes2)
        stopifnot(S4Vectors::isSingleString(matchPre))
        if (length(nchar(matchPre))) {
            start.field <- start.field[grep(paste0("^", matchPre), start.field)]
            end.field <- end.field[grep(paste0("^", matchPre), end.field)]
        }
        matchSuf <- intersect(suffixes1, suffixes2)
        stopifnot(S4Vectors::isSingleString(matchSuf))
        if (length(nchar(matchSuf))) {
            start.field <- start.field[grep(paste0(matchSuf, "$"), start.field)]
            end.field <- end.field[grep(paste0(matchSuf, "$"), end.field)]
        }
        idx1 <- which(df_colnames %in% start.field)
        idx2 <- which(df_colnames %in% end.field)
    } else if (!length(idx1) && !length(idx2)) {
        if (length(prefixes1) && length(prefixes2)) {
            if (length(prefixes1) >= 2L && length(prefixes2) >= 2L) {
                warning("multiple prefixes found, using first match")
                if (prefixes1[[1L]] == prefixes2[[1L]])
                    prefix <- prefixes1[[1L]]
            } else if (length(prefixes1) && length(prefixes2) &&
                       prefixes1 == prefixes2) {
                prefix <- prefixes1
            }
            idx1 <- which(df_colnames %in% paste0(prefix, start.field))
            idx2 <- which(df_colnames %in% paste0(prefix, end.field))
            if (length(idx1) == 1L && length(idx2) == 1L) {
                return(list(c(start = idx1, end = idx2), prefix)) }
        } else if (length(suffixes1) && length(suffixes2)) {
            if (length(suffixes1) >= 2L && length(suffixes2) >= 2L) {
                warning("multiple suffixes found, using first match")
                if (suffixes1[[1L]] == suffixes2[[1L]])
                    suffix <- suffixes1[[1L]]
            } else if (length(suffixes1) == 1L && length(suffixes2) == 1L &&
                       suffixes1 == suffixes2) {
                suffix <- suffixes1
            }
            idx1 <- which(df_colnames %in% paste0(start.field, suffix))
            idx2 <- which(df_colnames %in% paste0(end.field, suffix))
            if (length(idx1) == 1L && length(idx2) == 1L) {
                return(list(c(start = idx1, end = idx2), "")) }
        } else {
            return(list(c(start = NA_integer_, end = NA_integer_), ""))
        }
    }
    return(list(c(start = idx1, end = idx2), ""))
}

.find_seqnames_col <- function (df_colnames, seqnames.field, prefix) {
    idx <- which(df_colnames %in% paste0(prefix, seqnames.field))
    if (length(idx) == 0L)
        idx <- which(df_colnames %in% seqnames.field)
    if (length(idx) == 0L)
        return(NA_integer_)
    if (length(idx) >= 2L)
        warning("cannnot determine seqnames column unambiguously")
    return(idx[[1L]])
    idx
}

.collect_prefixes <- function (df_colnames, field) {
    df_colnames_nc <- nchar(df_colnames)
    prefixes <- lapply(field, function(suf) {
        pref_nc <- df_colnames_nc - nchar(suf)
        idx <- which(substr(df_colnames, pref_nc + 1L, df_colnames_nc) ==
                         suf)
        substr(df_colnames[idx], 1L, pref_nc[idx])
    })
    unique(unlist(prefixes))
}

.collect_suffixes <- function(df_colnames, field) {
    suffixes <- lapply(field, function(pre) {
        idx <- which(startsWith(df_colnames, pre))
        substr(df_colnames[idx], nchar(field) + 1L,
               nchar(df_colnames[idx]))
    })
    unique(unlist(suffixes))
}

.find_strands_col <- function(df_colnames, strand.field, prefix) {
    idx <- which(df_colnames %in% paste0(prefix, strand.field))
    if (length(idx) == 0L)
        idx <- which(df_colnames %in% strand.field)
    if (length(idx) == 0L)
        return(NA_integer_)
    if (length(idx) >= 2L) {
        warning("Multiple strand measurements detected, taking first one")
        idx <- idx[[1L]]
    }
    idx
}

findGRangesCols <- function (df_colnames,
                             seqnames.field = c("seqnames", "seqname",
                                                "chromosome", "chrom", "chr",
                                                "chromosome_name", "seqid"),
                             start.field = "start",
                             end.field = c("end", "stop"),
                             strand.field = "strand",
                             ignore.strand = FALSE) {
    df_colnames0 <- tolower(df_colnames)
    seqnames.field0 <- GenomicRanges:::.normarg_field(seqnames.field, "seqnames")
    start.field0 <- GenomicRanges:::.normarg_field(start.field, "start")
    end.field0 <- GenomicRanges:::.normarg_field(end.field, "end")
    start_end_cols <- .find_start_end_cols(df_colnames0, start.field0,
                                           end.field0)
    prefix <- start_end_cols[[2L]]
    width_col <- GenomicRanges:::.find_width_col(df_colnames0, "width", prefix)
    seqnames_col <- .find_seqnames_col(df_colnames0, seqnames.field0,
                                       prefix)
    if (ignore.strand) {
        strand_col <- NA_integer_
    }
    else {
        strand.field0 <- GenomicRanges:::.normarg_field(strand.field, "strand")
        strand_col <- .find_strands_col(df_colnames0, strand.field0, prefix)
    }
    c(seqnames = seqnames_col, start_end_cols[[1L]], width = width_col,
      strand = strand_col)
}
