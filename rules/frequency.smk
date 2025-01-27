import os

# =================================================================================================
#     HAFpipe Task 1:  Make SNP Table
# =================================================================================================

# We get the list of chromosomes from the config that the user wants HAFpipe to run for,
# and cross check them with the actual ref genome fai file, to avoid irritation.
# We use wildcard {chrom} here on purpose, instead of {contig} that we use for the rest of grenepipe,
# in order to (a) make it clear that these need to be actual sequences from the reference genome,
# and not our contig groups for example, and to (b) avoid accidents when matching the wildcards.
def get_hafpipe_chromosomes( fai ):
    ref_chrs = get_chromosomes( fai )
    haf_chrs = list( config["params"]["hafpipe"]["chromosomes"] )
    if len(haf_chrs) == 0:
        haf_chrs = ref_chrs
    haf_chrs = [ str(v) for v in haf_chrs ]
    for chr in haf_chrs:
        if not chr in ref_chrs:
            raise Exception(
                "Chromosome '" + chr + "' specified via the config `params: hafpipe: chromosomes` " +
                "list for running HAFpipe is not part of the reference genome."
            )
    return haf_chrs

# Same function as above, but wrapped to be used in a rule... Snakemake can be complicated...
def get_hafpipe_chromosomes_list(wildcards):
    fai = checkpoints.samtools_faidx.get().output[0]
    return get_hafpipe_chromosomes( fai )

# We allow users to specify a directory for the snp table, to avoid recomputation of Task 1.
def get_hafpipe_snp_table_dir():
    cfg_dir = config["params"]["hafpipe"]["snp-table-dir"]
    if cfg_dir:
        return cfg_dir.rstrip('/')
    return "hafpipe/snp-tables"

rule hafpipe_snp_table:
    input:
        vcf=config["params"]["hafpipe"]["founder-vcf"]
    output:
        snptable=get_hafpipe_snp_table_dir() + "/{chrom}.csv"
    params:
        tasks="1",
        chrom="{chrom}",
        extra=config["params"]["hafpipe"]["snp-table-extra"]
    log:
        "logs/hafpipe/snp-table/{chrom}.log"
    conda:
        "../envs/hafpipe.yaml"
    script:
        "../scripts/hafpipe.py"

# Get the list of snp table files.
def get_all_hafpipe_raw_snp_tables(wildcards):
    # We use the fai file of the ref genome to cross-check the list of chromosomes in the config.
    # We use a checkpoint to create the fai file from our ref genome, which gives us the chrom names.
    # Snakemake then needs an input function to work with the fai checkpoint here.
    fai = checkpoints.samtools_faidx.get().output[0]
    return expand(
        get_hafpipe_snp_table_dir() + "/{chrom}.csv",
        chrom=get_hafpipe_chromosomes( fai )
    )

# Rule that requests all HAFpipe SNP table files, so that users can impute them themselves.
rule all_hafpipe_snp_tables:
    input:
        get_all_hafpipe_raw_snp_tables

localrules: all_hafpipe_snp_tables

# =================================================================================================
#     HAFpipe Task 2:  Impute SNP Table
# =================================================================================================

# Edge case: HAFpipe allows "none" instead of empty for the impmethod.
# We get rid of this here for simplicity.
if config["params"]["hafpipe"]["impmethod"] == "none":
    config["params"]["hafpipe"]["impmethod"] = ""

# Shorthand
impmethod = config["params"]["hafpipe"]["impmethod"]

# We want to distinguish between the two impute methods that HAFpipe offers,
# and the case that the user provided their own script via the config file.

if impmethod in ["simpute", "npute"]:

    # Call the HAFpipe script with one of the two existing methods.
    rule hafpipe_impute_snp_table:
        input:
            snptable=get_hafpipe_snp_table_dir() + "/{chrom}.csv"
        output:
            # Unnamed output, as this is implicit in HAFpipe Task 2
            get_hafpipe_snp_table_dir() + "/{chrom}.csv" + "." + impmethod
        params:
            tasks="2",
            impmethod=impmethod,
            extra=config["params"]["hafpipe"]["impute-extra"]
        log:
            "logs/hafpipe/impute-" + impmethod + "/{chrom}.log"
        conda:
            "../envs/hafpipe.yaml"
        script:
            "../scripts/hafpipe.py"

elif impmethod != "":

    # Validity check of the custom script.
    if (
        not os.path.exists( config["params"]["hafpipe"]["impute-script"] ) or
        not os.access(config["params"]["hafpipe"]["impute-script"], os.X_OK)
    ):
        raise Exception(
            "User provided impute-script for HAFpipe does not exist or is not executable"
        )

    # Call the user provided script. No need for any of the HAFpipe parameters here.
    rule hafpipe_impute_snp_table:
        input:
            snptable=get_hafpipe_snp_table_dir() + "/{chrom}.csv"
        output:
            # Unnamed output, as this is implicit in the user script
            get_hafpipe_snp_table_dir() + "/{chrom}.csv" + "." + impmethod
        log:
            "logs/hafpipe/impute-" + impmethod + "/{chrom}.log"
        conda:
            # We use the custom conda env if the user provided it,
            # or just re-use the hafpipe env, for simplicity.
            (
                config["params"]["hafpipe"]["impute-conda"]
                if config["params"]["hafpipe"]["impute-conda"] != ""
                else "../envs/hafpipe.yaml"
            )
        shell:
            config["params"]["hafpipe"]["impute-script"] + " {input.snptable}"

# Helper to get the SNP table for a given chromosome. According to the `impmethod` config setting,
# this is either the raw table from Task 1 above, or the imputed table from Task 2, with either one
# of the established methods of HAFpipe, or a custom method/script provided by the user.
def get_hafpipe_snp_table(wildcards):
    base = get_hafpipe_snp_table_dir() + "/" + wildcards.chrom + ".csv"
    if config["params"]["hafpipe"]["impmethod"] in ["", "none"]:
        return base
    else:
        return base + "." + config["params"]["hafpipe"]["impmethod"]

# =================================================================================================
#     HAFpipe Tasks 3 & 4:  Infer haplotype frequencies & Calculate allele frequencies
# =================================================================================================

# We use the merged bam files of all bams per sample.
# The below rule is the same as the mpileup_merge_units rule in pileup.smk, but we do want this
# separate implemenation here, to have a bit more control of where the files go, and to stay
# independent of the mpileup rules. Bit of code duplication, might refactor in the future though.

rule hafpipe_merge_bams:
    input:
        get_sample_bams_wildcards # provided in mapping.smk
    output:
        # Making the bam files temporary is a bit dangerous, as an error in the calling of Task 4
        # after it has already written the header of the output file will lead to snakemake thinking
        # that the output is valid, hence deleting the bam files... Then, for re-running Task 4 we
        # need to first create the bam files again, which will then update Task 3, which takes ages...
        # But let's assume that all steps work ;-)
        (
            "hafpipe/bam/{sample}.merged.bam"
            if config["params"]["hafpipe"].get("keep-intermediates", True)
            else temp("hafpipe/bam/{sample}.merged.bam")
        )
    params:
        config["params"]["samtools"]["merge"]
    threads:
        config["params"]["samtools"]["merge-threads"]
    log:
        "logs/samtools/hafpipe/merge-{sample}.log"
    wrapper:
        "0.74.0/bio/samtools/merge"

# We run the two steps separately, so that if Task 4 fails,
# Task 3 does not have to be run again, hence saving time.

rule hafpipe_haplotype_frequencies:
    input:
        bamfile="hafpipe/bam/{sample}.merged.bam",     # provided above
        baifile="hafpipe/bam/{sample}.merged.bam.bai", # provided via bam_index rule in mapping.smk
        snptable=get_hafpipe_snp_table,                # provided above
        refseq=config["data"]["reference"]["genome"]
    output:
        # We currently just specify the output file names here as HAFpipe produces them.
        # Might want to refactor in the future to be able to provide our own names,
        # and have the script rename the files automatically.
        freqs=(
            "hafpipe/frequencies/{sample}.merged.bam.{chrom}.freqs"
            if config["params"]["hafpipe"].get("keep-intermediates", True)
            else temp("hafpipe/frequencies/{sample}.merged.bam.{chrom}.freqs")
        )
    params:
        tasks="3",
        outdir="hafpipe/frequencies",
        extra=config["params"]["hafpipe"]["haplotype-frequencies-extra"]
    log:
        "logs/hafpipe/frequencies/haplotype-{sample}.{chrom}.log"
    conda:
        "../envs/hafpipe.yaml"
    script:
        "../scripts/hafpipe.py"

rule hafpipe_allele_frequencies:
    input:
        bamfile="hafpipe/bam/{sample}.merged.bam",     # provided above
        baifile="hafpipe/bam/{sample}.merged.bam.bai", # provided via bam_index rule in mapping.smk
        snptable=get_hafpipe_snp_table,                # provided above
        freqs="hafpipe/frequencies/{sample}.merged.bam.{chrom}.freqs" # from Task 3 above
    output:
        # Same as above: just expect the file name as produced by HAFpipe.
        afSite=(
            "hafpipe/frequencies/{sample}.merged.bam.{chrom}.afSite"
            if config["params"]["hafpipe"].get("keep-intermediates", True)
            else temp("hafpipe/frequencies/{sample}.merged.bam.{chrom}.afSite")
        )
    params:
        tasks="4",
        outdir="hafpipe/frequencies",
        extra=config["params"]["hafpipe"]["allele-frequencies-extra"]
    log:
        "logs/hafpipe/frequencies/allele-{sample}.{chrom}.log"
    conda:
        "../envs/hafpipe.yaml"
    script:
        "../scripts/hafpipe.py"

# =================================================================================================
#     HAFpipe Collect All
# =================================================================================================

# Get the afSite file list. As this is task 4, task 3 will also be executed,
# but we keep it simple here and only request the final files.
def collect_all_hafpipe_allele_frequencies(wildcards):
    # We use the fai file of the ref genome to cross-check the list of chromosomes in the config.
    # We use a checkpoint to create the fai file from our ref genome, which gives us the chrom names.
    # Snakemake then needs an input function to work with the fai checkpoint here.
    fai = checkpoints.samtools_faidx.get().output[0]
    return expand(
        "hafpipe/frequencies/{sample}.merged.bam.{chrom}.afSite",
        sample=config["global"]["sample-names"],
        chrom=get_hafpipe_chromosomes( fai )
    )

# Merge all afSite files produced above, for all samples and all chromsomes.
# The script assumes the exact naming scheme that we use above, so it is not terribly portable...
rule hafpipe_merge_allele_frequencies:
    input:
        # We only request the input files here so that snakemake knows that we need them.
        # The script that we are running does not access the input list at all, as it is just a
        # big mess of files. We instead want the structured way of finding our files using the
        # lists of samples and chromosomes that we hand over via the params below.
        # This is unfortunately necessary, as HAFpipe afSite files do not contain any information
        # on their origins (samples and chromosomes) other than their file names, so we have to
        # work with that... See the script for details.
        collect_all_hafpipe_allele_frequencies
    output:
        # This is the file name produced by the script. For now we do not allow to change this.
        table="hafpipe/all.csv" + (
            ".gz" if config["params"]["hafpipe"].get("compress-merged-table", False) else ""
        )
    params:
        # We are potentially dealing with tons of files, and cannot open all of them at the same
        # time, due to OS limitations, check `ulimit -n` for example. When this param is set to 0,
        # we try to use that upper limit (minus some tolerance). However, if that fails, this value
        # can be manually set to a value below the limit, to make it work, e.g., 500
        concurrent_files=0,

        # The rule needs access to lists of samples and chromosomes,
        # and we give it the base path of the afSite files as well, for a little bit of flexibility.
        samples=config["global"]["sample-names"],
        chroms=get_hafpipe_chromosomes_list,

        # We provide the paths to the input directory here. The output will be written to the
        # parent directory of that (so, to "hafpipe").
        # Ugly, but we are dealing with HAFpipe uglines here, and that seems to be easiest for now.
        base_path="hafpipe/frequencies",

        # We might want to compress the final output.
        compress=config["params"]["hafpipe"].get("compress-merged-table", False)
    log:
        "logs/hafpipe/merge-all.log"
    script:
        "../scripts/hafpipe-merge.py"

# Simple rule that requests all hafpipe af files, so that they get computed.
# Will probably extend this in the future to a rule that combines all of them into one file.
rule all_hafpipe:
    input:
        "hafpipe/all.csv" + (
            ".gz" if config["params"]["hafpipe"].get("compress-merged-table", False) else ""
        )
        # collect_all_hafpipe_allele_frequencies

localrules: all_hafpipe
