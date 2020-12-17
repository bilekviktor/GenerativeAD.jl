using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
using GenerativeAD.Models: anomaly_score, generalized_anomaly_score_gpu
using BSON
using StatsBase: fit!, predict, sample

using Flux
using MLDataPattern

s = ArgParseSettings()
@add_arg_table! s begin
   "max_seed"
		required = true
		arg_type = Int
		help = "seed"
	"dataset"
		required = true
		arg_type = String
		help = "dataset"
end
parsed_args = parse_args(ARGS, s)
@unpack dataset, max_seed = parsed_args

modelname ="DeepSVDD"

function sample_params()
	argnames = (
		:hdim, 
		:zdim, 
		:nlayers, 
        :activation, 
        :objective, 
        :nu,
        :lr_svdd, 
        :lr_ae,
		:batch_size, 
		:init_seed,
	)
	par_vec = (
		2 .^(4:9),
		2 .^(3:8),
		3:4,
        ["relu", "swish", "tanh"],
        ["soft-boundary", "one-class"],
        [0.01f0, 0.1f0, 0.5f0, 0.99f0], # paper 0.1
        10f0 .^ (-4:-3),
        10f0 .^ (-4:-3),
		2 .^ (5:7),
		1:Int(1e8),
	)
	return NamedTuple{argnames}(map(x->sample(x,1)[1], par_vec))
end


function fit(data, parameters)
	all_parameters = merge(
		parameters, 
		(
			iters=5000, 
			check_every=30, 
			ae_check_every = 30,
			patience=10, 
			ae_iters=5000
		)
	)
    
    svdd = GenerativeAD.Models.ae_constructor(;all_parameters...) |> gpu

	# define optimiser
	try
		global info, fit_t, _, _, _ = @timed fit!(svdd, data, all_parameters)
	catch e
		println("Error caught => $(e).")
		return (fit_t = NaN, model = nothing, history = nothing, n_parameters = NaN), []
	end

    training_info = (
		fit_t = fit_t,
		model = info[2]|>cpu,
		history_svdd = info[1][1], # losses through time
		history_ae = info[1][2],
		npars = info[3], # number of parameters
		iters = info[4] # optim iterations of model
		)


    return training_info, [(x -> GenerativeAD.Models.anomaly_score_gpu(svdd, x), parameters)] 
    # if there is no gpu on pc anomaly_score will automaticly run on cpu
end

#_________________________________________________________________________________________________

try_counter = 0
max_tries = 10*max_seed

while try_counter < max_tries
	parameters = sample_params()

	for seed in 1:max_seed
		savepath = datadir("experiments/tabular/$(modelname)/$(dataset)/seed=$(seed)")

        data = GenerativeAD.load_data(dataset, seed=seed)
        
        @info "Trying to fit $modelname on $dataset with parameters $(parameters)..."
		@info "Train/validation/test splits: $(size(data[1][1], 2)) | $(size(data[2][1], 2)) | $(size(data[3][1], 2))"
		@info "Number of features: $(size(data[1][1])[1])"

		# update parameter
		parameters = merge(parameters, (idim=size(data[1][1],1), ))
		# here, check if a model with the same parameters was already tested
		if GenerativeAD.check_params(savepath, parameters)
			#(X_train,_), (X_val, y_val), (X_test, y_test) = data
			training_info, results = fit(data, parameters)
			# saving model separately
			if training_info.model !== nothing
				tagsave(joinpath(savepath, savename("model", parameters, "bson")), Dict("model"=>training_info.model), safe = true)
				training_info = merge(training_info, (model = nothing,))
			end
			save_entries = merge(training_info, (modelname = modelname, seed = seed, dataset = dataset))
			# now loop over all anomaly score funs
			for result in results
				GenerativeAD.experiment(result..., data, savepath; save_entries...)
			end
			global try_counter = max_tries + 1
		else
			@info "Model already present, sampling new hyperparameters..."
			global try_counter += 1
		end
	end
end
(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing