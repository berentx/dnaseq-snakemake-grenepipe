# =================================================================================================
#     Trimming
# =================================================================================================

# Switch to the chosen mapper
if config["settings"]["trimming-tool"] == "adapterremoval":

    # Use `adapterremoval`
    include: "trimming-adapterremoval.smk"

elif config["settings"]["trimming-tool"] == "cutadapt":

    # Use `cutadapt`
    include: "trimming-cutadapt.smk"

elif config["settings"]["trimming-tool"] == "fastp":

    # Use `fastp`
    include: "trimming-fastp.smk"

elif config["settings"]["trimming-tool"] == "seqprep":

    # Use `seqprep`
    include: "trimming-seqprep.smk"

elif config["settings"]["trimming-tool"] == "skewer":

    # Use `skewer`
    include: "trimming-skewer.smk"

elif config["settings"]["trimming-tool"] == "trimmomatic":

    # Use `trimmomatic`
    include: "trimming-trimmomatic.smk"

else:
    raise Exception("Unknown trimming-tool: " + config["settings"]["trimming-tool"])
