#!/usr/bin/env nextflow

/*
========================================================================================
                  Virus Genome Mapping Pipeline
========================================================================================
 Github Repo:
 Greninger Lab
 
 Author:
 Paul RK Cruz <kurtisc@uw.edu>
----------------------------------------------------------------------------------------
Pipeline overview:
 - 1. : Fastq File Processing
 		-FastQC - sequence read quality control.
 		-Trimmomatic - sequence trimming of adaptors and low quality reads.
 - 2. : Genome Mapping
 		-Bowtie2 - Remove host genome and map to reference Virus genome.
 		-Samtools - SAM and BAM file processing.
 - 3. : Variant calling, annotation and consensus:
  		-Bcftools - Consensus in *.fasta format

  Dependencies:
  
  fastqc
  trimmomatic
  bowtie2
  samtools
  bedtools
  Bcftools

 ----------------------------------------------------------------------------------------
*/


def helpmsg() {

    log.info""""
    ____________________________________________
     Virus Genome Mapping Pipeline :  v${version}
    ____________________________________________
    
	Pipeline Usage:

    To run the pipeline, enter the following in the command line:

        nextflow run Virus_Genome_Mapping_Pipeline/main.nf --reads PATH_TO_FASTQ --viral_fasta .PATH_TO_VIR_FASTA --viral_index PATH_TO_VIR_INDEX --host_fasta PATH_TO_HOST_FASTA --host_index PATH_TO_HOST_INDEX --outdir ./output


    Valid CLI Arguments:
      --reads                       Path to input fastq.gz folder).
      --viral_fasta                 Path to fasta reference sequences (concatenated)
      --viral_index                 Path to indexed virus reference databases
      --host_fasta                  Path to host Fasta sequence
      --host_index                  Path to host fasta index
      --singleEnd                   Specifies that the input fastq files are single end reads
      --notrim                      Specifying --notrim will skip the adapter trimming step
      --saveTrimmed                 Save the trimmed Fastq files in the the Results directory
      --trimmomatic_adapters_file   Adapters index for adapter removal
      --trimmomatic_mininum_length  Minimum length of reads
      --outdir                      The output directory where the results will be saved

    """.stripIndent()
}
// Check Nextflow version
nextflow_req_v = '20.10.0'
try {
    if( ! nextflow.version.matches(">= $nextflow_req_v") ){
        throw GroovyException('> ERROR: The version of Nextflow running on your machine is out dated.\n>Please update to Version '$nextflow_req_v)
    }
} catch (all) {
	log.error"ERROR: This version of Nextflow is out of date.\nPlease update to the latest version of Nextflow."
}
/*
 * Configuration Setup
 */
params.help = false

// Pipeline version
version = '1.0'

// Show help msg
if (params.help){
    helpmsg()
    exit 0
}
// Check for virus genome reference indexes
params.viral_fasta = false
if( params.viral_fasta ){
    viral_fasta_file = file(params.viral_fasta)
    if( !viral_fasta_file.exists() ) exit 1, "> Virus fasta file not found: ${params.viral_fasta}.\n> Please specify a valid file path!"
}
// Check for host genome reference indexes
params.host_fasta = false
if( params.host_fasta ){
    host_fasta_file = file(params.host_fasta)
    if( !host_fasta_file.exists() ) exit 1, "> Host fasta file not found: ${params.host_fasta}.\n> Please specify a valid file path!"
}
// Channel for input fastq files
Channel
    .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
    .ifEmpty { exit 1, "> Invalid sequence read type.\n> Please retry with --singleEnd" }
    .into { raw_reads_fastqc; raw_reads_trimming }

if( params.viral_index ){
// Channel for virus genome reference indexes
	Channel
        .fromPath(params.viral_index)
        .ifEmpty { exit 1, "> Error: Virus index not found: ${params.viral_index}.\n> Please specify a valid file path!"}
        .into { viral_index_files; viral_index_files_ivar; viral_index_files_variant_calling }
}
// Channel for host genome reference indexes
if( params.host_index ){
	Channel
        .fromPath(params.host_index)
        .ifEmpty { exit 1, "> Host index not found: ${params.host_index}.\n> Please specify a valid file path!"}
        .into { host_index_files }
}
// Check for fastq
params.reads = false
if (! params.reads ) exit 1, "> Error: Fastq files not found: $params.reads. Please specify a valid path with --reads"
// Single-end read option
params.singleEnd = false
// Trimming parameters
params.notrim = false
// Output files options
params.saveTrimmed = false
// Default trimming options
params.trimmomatic_adapters_file = "\$TRIMMOMATIC_PATH/adapters/NexteraPE-PE.fa"
params.trimmomatic_adapters_parameters = "2:30:10"
params.trimmomatic_window_length = "4"
params.trimmomatic_window_value = "20"
params.trimmomatic_mininum_length = "50"

// log files header
log.info "____________________________________________"
log.info " Virus Genome Mapping Pipeline :  v${version}"
log.info "____________________________________________"
def summary = [:]
summary['Fastq Files:']               = params.reads
summary['Read type:']           = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Virus Reference:']           = params.viral_fasta
summary['Container:']           = workflow.container
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Current directory path:']        = "$PWD"
summary['Working directory path:']         = workflow.workDir
summary['Output directory path:']          = params.outdir
summary['Pipeline directory path:']          = workflow.projectDir
if( params.notrim ){
    summary['Trimmomatic Options: '] = 'Skipped trimming step'
} else {
    summary['Trimmomatic adapters:'] = params.trimmomatic_adapters_file
    summary['Trimmomatic adapter parameters:'] = params.trimmomatic_adapters_parameters
    summary["Trimmomatic read length (minimum):"] = params.trimmomatic_mininum_length
}
summary['Configuration Profile:'] = workflow.profile
log.info summary.collect { k,v -> "${k.padRight(21)}: $v" }.join("\n")
log.info "____________________________________________"

/*
 * Fastq File Processing
 * 
 * Fastqc
 */
process fastqc {
	label "small"
	tag "$prefix"
	publishDir "${params.outdir}/01-fastQC", mode: 'copy',
		saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

	input:
	set val(name), file(reads) from raw_reads_fastqc

	output:
	file '*_fastqc.{zip,html}' into fastqc_results
	file '.command.out' into fastqc_stdout

	script:

	prefix = name - ~/(_S[0-9]{2})?(_L00[1-9])?(.R1)?(_1)?(_R1)?(_trimmed)?(_val_1)?(_00*)?(\.fq)?(\.fastq)?(\.gz)?$/
	"""
	mkdir tmp
	fastqc -t ${task.cpus} -dir tmp $reads
	rm -rf tmp
	"""
}

/*
 * Trimm sequence reads
 * 
 * Trimmomatic
 */
process trimming {
	label "small"
	tag "$prefix"
	publishDir "${params.outdir}/02-preprocessing", mode: 'copy',
		saveAs: {filename ->
			if (filename.indexOf("_fastqc") > 0) "../03-preprocQC/$filename"
			else if (filename.indexOf(".log") > 0) "logs/$filename"
      else if (params.saveTrimmed && filename.indexOf(".fastq.gz")) "trimmed/$filename"
			else null
	}

	input:
	set val(name), file(reads) from raw_reads_trimming

	output:
	file '*_paired_*.fastq.gz' into trimmed_paired_reads,trimmed_paired_reads_bwa,trimmed_paired_reads_bwa_virus
	file '*_unpaired_*.fastq.gz' into trimmed_unpaired_reads
	file '*_fastqc.{zip,html}' into trimmomatic_fastqc_reports
	file '*.log' into trimmomatic_results

	script:
	prefix = name - ~/(_S[0-9]{2})?(_L00[1-9])?(.R1)?(_1)?(_R1)?(_trimmed)?(_val_1)?(_00*)?(\.fq)?(\.fastq)?(\.gz)?$/
	"""
	trimmomatic PE -threads ${task.cpus} -phred33 $reads $prefix"_paired_R1.fastq" $prefix"_unpaired_R1.fastq" $prefix"_paired_R2.fastq" $prefix"_unpaired_R2.fastq" ILLUMINACLIP:${params.trimmomatic_adapters_file}:${params.trimmomatic_adapters_parameters} SLIDINGWINDOW:${params.trimmomatic_window_length}:${params.trimmomatic_window_value} MINLEN:${params.trimmomatic_mininum_length} 2> ${name}.log

	gzip *.fastq
	mkdir tmp
	fastqc -t ${task.cpus} -q *_paired_*.fastq.gz
	rm -rf tmp

	"""
}

/*
 * Map sequence reads to human host
 * 
 * Map to host for host removal
 */
process mapping_host {
	tag "$prefix"
	publishDir "${params.outdir}/04-mapping_host", mode: 'copy',
		saveAs: {filename ->
			if (filename.indexOf(".bam") > 0) "mapping/$filename"
			else if (filename.indexOf(".bai") > 0) "mapping/$filename"
      else if (filename.indexOf(".txt") > 0) "stats/$filename"
      else if (filename.indexOf(".stats") > 0) "stats/$filename"
	}

	input:
	set file(readsR1),file(readsR2) from trimmed_paired_reads_bwa
  file refhost from host_fasta_file
  file index from host_index_files.collect()

	output:
	file '*_sorted.bam' into mapping_host_sorted_bam
  file '*.bam.bai' into mapping_host_bai
	file '*_flagstat.txt' into mapping_host_flagstat
	file '*.stats' into mapping_host_picardstats

	script:
	prefix = readsR1.toString() - '_paired_R1.fastq.gz'
	"""
  bowtie2 -p ${task.cpus} --local -x $refhost -1 $readsR1 -2 $readsR2 --very-sensitive-local -S $prefix".sam"
  samtools sort -o $prefix"_sorted.bam" -O bam -T $prefix $prefix".sam"
  samtools index $prefix"_sorted.bam"
  samtools flagstat $prefix"_sorted.bam" > $prefix"_flagstat.txt"
	"""
}

/*
 * STEPS 2.2 Mapping virus
 */
process mapping_virus {
	tag "$prefix"
	publishDir "${params.outdir}/05-mapping_virus", mode: 'copy',
		saveAs: {filename ->
			if (filename.indexOf(".bam") > 0) "mapping/$filename"
			else if (filename.indexOf(".bai") > 0) "mapping/$filename"
      else if (filename.indexOf(".txt") > 0) "stats/$filename"
      else if (filename.indexOf(".stats") > 0) "stats/$filename"
	}

	input:
	set file(readsR1),file(readsR2) from trimmed_paired_reads_bwa_virus
  file refvirus from viral_fasta_file
  file index from viral_index_files.collect()

	output:
	file '*_sorted.bam' into mapping_virus_sorted_bam,mapping_virus_sorted_bam_variant_calling,mapping_virus_sorted_bam_consensus
  file '*.bam.bai' into mapping_virus_bai,mapping_virus_bai_variant_calling,mapping_virus_bai_consensus
	file '*_flagstat.txt' into mapping_virus_flagstat
	file '*.stats' into mapping_virus_picardstats

	script:
  prefix = readsR1.toString() - '_paired_R1.fastq.gz'
	"""
  bowtie2 -p ${task.cpus} --local -x $refvirus -1 $readsR1 -2 $readsR2 --very-sensitive-local -S $prefix".sam"
  samtools sort -o $prefix"_sorted.bam" -O bam -T $prefix $prefix".sam"
  samtools index $prefix"_sorted.bam"
  samtools flagstat $prefix"_sorted.bam" > $prefix"_flagstat.txt"
	"""
}

/*
 * STEPS 3.3 Consensus Genome
 */
process genome_consensus {
  tag "$prefix"
  publishDir "${params.outdir}/08-mapping_consensus", mode: 'copy',
		saveAs: {filename ->
			if (filename.indexOf("_consensus.fasta") > 0) "consensus/$filename"
			else if (filename.indexOf("_consensus_masked.fasta") > 0) "masked/$filename"
	}

  input:
  file variants from majority_allele_vcf_consensus
  file refvirus from viral_fasta_file
  file sorted_bam from sorted_bam_consensus
  file sorted_bai from bai_consensus

  output:
  file '*_consensus.fasta' into consensus_fasta
  file '*_consensus_masked.fasta' into masked_fasta

  script:
  prefix = variants.baseName - ~/(_majority)?(_paired)?(\.vcf)?(\.gz)?$/
  refname = refvirus.baseName - ~/(\.2)?(\.fasta)?$/
  """
  bgzip -c $variants > $prefix"_"$refname".vcf.gz"
  bcftools index $prefix"_"$refname".vcf.gz"
  cat $refvirus | bcftools consensus $prefix"_"$refname".vcf.gz" > $prefix"_"$refname"_consensus.fasta"
  bedtools genomecov -bga -ibam $sorted_bam -g $refvirus | awk '\$4 < 20' | bedtools merge > $prefix"_"$refname"_bed4mask.bed"
  bedtools maskfasta -fi $prefix"_"$refname"_consensus.fasta" -bed $prefix"_"$refname"_bed4mask.bed" -fo $prefix"_"$refname"_consensus_masked.fasta"
  sed -i 's/$refname/$prefix/g' $prefix"_"$refname"_consensus_masked.fasta"
  """
}
