using ArgParse
using DrWatson
@quickactivate
using CSV
using BSON
using Random
using FileIO
using DataFrames
using PrettyTables
using PrettyTables.Crayons

using GenerativeAD.Evaluation: _prefix_symbol, PAT_METRICS, aggregate_stats_mean_max
using GenerativeAD.Evaluation: rank_table, print_rank_table
using GenerativeAD.Datasets: load_data

s = ArgParseSettings()
@add_arg_table! s begin
	"filename"
		arg_type = String
		default = "evaluation/images_eval.bson"
		help = "Location of cached DataFrame."
	"-c", "--criterion-metric"
		arg_type = String
		default = "val_auc"
		help = "Criterion to sort the models."
	"-r", "--rank-metric"
		arg_type = String
		default = "tst_auc"
		help = "Metric to rank models."
	"-o", "--output-prefix"
		arg_type = String
		default = "evaluation/images_eval"
		help = "Output prefix for storing results."
    "-f", "--force"
    	action = :store_true
		help = "Overwrite all generated files."
end


# args = Dict()
# args["filename"] = "evaluation/tabular_sptn_5seeds_quantiles_eval.bson"
# args["criterion-metric"] = "val_tpr_5"
# args["rank-metric"] = "tst_tpr_5"
# args["output-prefix"] = "evaluation/zkouska_graf_rel_params2.bson"
# args["max-params"] = 100
#
# f = datadir(args["filename"])
# df = load(f)[:df]
# cdf = deepcopy(df)
#
# tdf = deepcopy(cdf)
# for i in 1:1
# 	tdf = deepcopy(cdf)
# 	for d in unique(cdf[:dataset])
# 		mx = maximum(cdf[cdf[:dataset] .== d, :npars])
# 		filter!(row -> (row[:dataset] .!= d) .| ((row[:dataset] .== d) .& (row[:npars] .<= i/100 .* mx)), tdf)
# 	end
# 	println(i)
# end
#
# data_dim(s) = size(load_data(s)[1][1], 1)
# datadim = Dict()
# for d in unique(df[:dataset])
#     println(d)
#     datadim[d] = size(load_data(d)[1][1], 1)
# end
# df[data_dim.(df[:dataset]) .== 10]
#
# cdf.datadim = 1
# cdf.relnpars = 1.0
# for f in eachrow(cdf)
#     @show f.datadim = datadim[f[:dataset]]
#     @show f.relnpars = f[:npars]/f[:datadim]
# end
#
# df_agg = aggregate_stats_mean_max(cdf, "val_auc")
# rt = rank_table(df_agg, "tst_auc")
#
# npar_df = DataFrame(modelname = String[],relnpars = Float64[], rank = Float64[])
# for i in minimum(cdf[:relnpars]):10:maximum(cdf[:relnpars])
#     df_agg = aggregate_stats_mean_max(cdf[cdf[:relnpars] .<= i, :], "val_auc")
#     rt = rank_table(df_agg, "tst_auc")
#     for n in names(rt)[2:end]
#         push!(npar_df, (n, i, rt[end, n]))
#     end
#     println(i)
# end
# npar_df
# using Plots
# sptn_df = npar_df[npar_df[:modelname] .== "sptn", :]
# sptn_5_df = npar_df[npar_df[:modelname] .== "sptn_005_010", :]
# sptn_25_df = npar_df[npar_df[:modelname] .== "sptn_0025_0075", :]
# plot(sptn_df[:relnpars], sptn_df[:rank])
# plot!(sptn_5_df[:relnpars], sptn_5_df[:rank])
# plot!(sptn_25_df[:relnpars], sptn_25_df[:rank])


function main(args)
	f = datadir(args["filename"])
	df = load(f)[:df]
    cdf = deepcopy(df)

    #data dim dict
    data_dim(s) = size(load_data(s)[1][1], 1)
    datadim = Dict()
    for d in unique(df[:dataset])
        datadim[d] = size(load_data(d)[1][1], 1)
    end

    # cdf.datadim = 1
    # cdf.relnpars = 1.0
    # for f in eachrow(cdf)
    #     f.datadim = datadim[f[:dataset]]
    #     #relnpars = numb. of params of model / data dim.
    #     f.relnpars = f[:npars]/f[:datadim]
    # end
	@info "Loaded $(nrow(df)) rows from $f"

    # Dataframe for final ranks for each relnpars
    npar_df = DataFrame(modelname = String[],relnpars = Float64[], rank = Float64[])

    # m = args["max-params"]
    # if m == -1
    #     m = maximum(cdf[:relnpars])
    # end
	#
    # for i in minimum(cdf[:relnpars]):1:m
    #     # evaluation and rank table
    #     df_agg = aggregate_stats_mean_max(cdf[cdf[:relnpars] .<= i, :], Symbol(args["criterion-metric"]))
    #     rt = rank_table(df_agg, args["rank-metric"])
    #     for n in names(rt)[2:end]
    #         # row for each model at relnpars
    #         push!(npar_df, (n, i, rt[end, n]))
    #     end
	# 	@info "Number of relative parameters $i"
    # end

	for i in 1:100
		tdf = deepcopy(cdf)
		for d in unique(cdf[:dataset])
			mx = maximum(cdf[cdf[:dataset] .== d, :npars])
			filter!(row -> (row[:dataset] .!= d) .| ((row[:dataset] .== d) .& (row[:npars] .<= i/100 .* mx)), tdf)
		end
		# display(size(tdf))
		df_agg = aggregate_stats_mean_max(tdf, Symbol(args["criterion-metric"]))
		rt = rank_table(df_agg, args["rank-metric"])

        for n in names(rt)[2:end]
            # row for each model at relnpars
            push!(npar_df, (n, i, rt[end, n]))
        end

		@info "Percent of relative parameters $i %"
	end

	@info "Best models chosen by $(args["criterion-metric"])"
	@info "Ranking by $(args["rank-metric"])"

    ff = datadir(args["output-prefix"])
	if (isfile(ff) && args["force"]) || ~isfile(ff)
		@info "Saving $(nrow(npar_df)) rows to $ff."
		wsave(ff, Dict(:df => npar_df))
	end
	@info "---------------- DONE -----------------"
end

main(parse_args(ARGS, s))
