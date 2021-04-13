using ArgParse
using DrWatson
@quickactivate
using BSON
using Random
using FileIO
using DataFrames
using Base.Threads: @threads
using GenerativeAD

# pkgs which come from deserialized BSONs
# have to be present in the Main module
using ValueHistories
using LinearAlgebra

s = ArgParseSettings()
@add_arg_table! s begin
    "source_prefix"
		arg_type = String
		default = "experiments/images"
		help = "Data prefix of experiment files."
	"target_prefix"
		arg_type = String
		default = "evaluation/images"
		help = "Data prefix of generated files."
	"-f", "--force"
    	action = :store_true
		help = "Overwrite all generated files."
end

"""
	generate_stats(source_prefix::String, target_prefix::String; force=true)

Collects all the results from experiments in datadir prefix `source_prefix`,
computes evaluation metrics and stores results in datadir prefix `target_prefix`
while retaining the folder structure. If `force=true` the function overwrites
already precomputed results.
"""
function generate_stats(source_prefix::String, target_prefix::String; force=true)
	(source_prefix == target_prefix) && error("Results have to be stored in different folder.")

	source = datadir(source_prefix)
	@info "Collecting files from $source folder."
	files = GenerativeAD.Evaluation.collect_files_th(source)
	# filter out model files
	filter!(x -> !startswith(basename(x), "model"), files)
	@info "Collected $(length(files)) files from $source folder."
	# it might happen that when appending results some of the cores
	# just go over already computed files
	files = files[randperm(length(files))]

	@threads for f in files
		target_dir = dirname(replace(f, source_prefix => target_prefix))
		target = joinpath(target_dir, "eval_$(basename(f))")
		try
			if (isfile(target) && force) || ~isfile(target)
				df = GenerativeAD.Evaluation.compute_quantile_stats(f)
				wsave(target, Dict(:df => df))
				@info "Saving evaluation results at $(target)"
			end
		catch e
			# remove old files in order to ensure consistency
			if (isfile(target) && force)
				rm(target)
			end
			@warn "Processing of $f failed due to \n$e"
		end
	end
end

function main(args)
	generate_stats(
		args["source_prefix"],
		args["target_prefix"];
		force=args["force"])
	@info "---------------- DONE -----------------"
end

main(parse_args(ARGS, s))
