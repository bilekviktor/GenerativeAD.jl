using ArgParse
using GenerativeAD
import StatsBase: fit!, predict, sample
using DrWatson
@quickactivate
using BSON

s = ArgParseSettings()
@add_arg_table! s begin
   "seed"
        required = true
        arg_type = Int
        help = "seed"
    "dataset"
        required = true
        arg_type = String
        help = "dataset"
end
parsed_args = parse_args(ARGS, s)
@unpack dataset, seed = parsed_args

modelname = "pidforest"
function sample_params()
	par_vec = (6:2:10, 50:25:200, 50:50:200, 3:6, [0.05, 0.1, 0.2], )
	argnames = (:max_depth, :n_trees, :max_samples, :max_buckets, :epsilon, )

	return (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
end

function fit(data, parameters)
	model = GenerativeAD.Models.PIDForest(Dict(pairs(parameters)))

	try
		global info, fit_t, _, _, _ = @timed fit!(model, data[1][1])
	catch e
		@info "Failed training PIDForest$(parameters) due to \n$e"
		return (fit_t = NaN,), []
	end

	training_info = (
		fit_t = fit_t,
		model = nothing
		)

	# there are parameters for the predict function, which could be specified here and put into parameters
	training_info, [(x -> predict(model, x, pct=p), merge(parameters, Dict(:percentile => p))) for p in [10, 25, 50]]
end

savepath = datadir("experiments/tabular/$(modelname)/$(dataset)/seed=$(seed)") 
mkpath(savepath)

data = GenerativeAD.load_data(dataset, seed=seed)

try_counter = 0
max_tries = 10
while try_counter < max_tries 
	parameters = sample_params()
	# here, check if a model with the same parameters was already tested
	if GenerativeAD.check_params(GenerativeAD.edit_params, savepath, data, parameters)
		# fit
		training_info, results = fit(data, parameters)
		# here define what additional info should be saved together with parameters, scores, labels and predict times
		save_entries = merge(training_info, (modelname = modelname, seed = seed, dataset = dataset))
		
		# now loop over all anomaly score funs
		for result in results
			GenerativeAD.experiment(result..., data, savepath; save_entries...)
		end
		break
	else
		@info "Model already present, sampling new hyperparameters..."
		global try_counter += 1
	end 
end
(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing