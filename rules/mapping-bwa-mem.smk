# =================================================================================================
#     Read Mapping
# =================================================================================================

def get_bwa_mem_extra( wildcards ):
    rg_tags = "\\t".join( get_read_group_tags(wildcards) )
    extra = "-R '@RG\\t" + rg_tags + "' " + config["params"]["bwamem"]["extra"]
    return extra

rule map_reads:
    input:
        reads=get_trimmed_reads,
        ref=config["data"]["reference"]["genome"],
        refidcs=expand(
            config["data"]["reference"]["genome"] + ".{ext}",
            ext=[ "amb", "ann", "bwt", "pac", "sa", "fai" ]
        )
    output:
        "mapped/{sample}-{unit}.sorted.bam"
    params:
        index=config["data"]["reference"]["genome"],
        extra=get_bwa_mem_extra,

        # Sort as we need it.
        sort="samtools",
        sort_order="coordinate",
        sort_extra=config["params"]["bwamem"]["extra-sort"]
    group:
        "mapping"
    log:
        "logs/bwa-mem/{sample}-{unit}.log"
    benchmark:
        "benchmarks/bwa-mem/{sample}-{unit}.bench.log"
    threads:
        config["params"]["bwamem"]["threads"]
    conda:
        "../envs/bwa.yaml"
    # resources:
        # Increase time limit in factors of 2h, if the job fails due to time limit.
        # time = lambda wildcards, input, threads, attempt: int(120 * int(attempt))

    # We need a full shadow directory, as `samtools sort` creates a bunch of tmp files that mess
    # up any later attempts, as `samtools sort` terminates if these files are already present.
    # We experimented with all kinds of other solutions, such as setting the `-T` option of
    # `samtools sort` via the `sort_extra` param, and creating and deleting tmp directories for that,
    # but that fails due to issues with snakemake handling directories instead of files...
    # The snakemake shadow rule here seems to do the job. At least, if we understood their mediocre
    # documentation correctly...
    shadow:
        "full"
    wrapper:
        "0.51.3/bio/bwa/mem"
