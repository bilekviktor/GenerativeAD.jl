using Flux
using StatsBase
using Distributions
using DistributionsAD
using ContinuousFlows: RealNVP, MaskedAutoregressiveFlow
using ValueHistories
using MLDataPattern: RandomBatches

abstract type TabularFlow end

struct RealNVPFlow <: TabularFlow
	flows
	base
end

function RealNVPFlow(;idim::Int=1, nflows::Int=2, hdim::Int=10, nlayers::Int=2,
						act_loc="relu", act_scl="tanh",	init_seed=nothing,
						bn=true, init_I=true, tanhscaling=false, kwargs...)
	# if seed is given, set it
	(init_seed != nothing) ? Random.seed!(init_seed) : nothing

	builders = (α=(d, o) -> build_mlp(d, hdim, o, nlayers, activation=act_loc, lastlayer="linear"),
				β=(d, o) -> build_mlp(d, hdim, o, nlayers, activation=act_scl, lastlayer="linear"))
	model = RealNVPFlow(Chain([
		RealNVP(
			idim,
			builders,
			mod(i,2) == 0;
			use_batchnorm=bn,
			tanh_scaling=tanhscaling,
			lastzero=true)
		for i in 1:nflows]...), MvNormal(idim, 1.0f0))

	# reset seed
	(init_seed != nothing) ? Random.seed!() : nothing

	model
end

(nvpf::RealNVPFlow)(X) = nvpf.flows(X)
Flux.trainable(nvpf::RealNVPFlow) = (nvpf.flows, )

function Base.show(io::IO, nvpf::RealNVPFlow)
	# to avoid the show explosion
	print(io, "RealNVPFlow(flows=$(length(nvpf.flows)), idim=$(length(nvpf.base)))")
end

struct MAF <: TabularFlow
	flows
	base
end

function MAF(;idim::Int=1, nflows::Int=2, hdim::Int=10, nlayers::Int=2,
				act_loc="relu", act_scl="tanh",	ordering::String="natural",
				init_seed=nothing, bn=true, init_I=true, kwargs...)
	# if seed is given, set it
	(init_seed != nothing) ? Random.seed!(init_seed) : nothing

	model = MAF(Chain([
		MaskedAutoregressiveFlow(
			idim,
			hdim,
			nlayers,
			idim,
			(α=eval(:($(Symbol(act_loc)))), β=eval(:($(Symbol(act_scl))))),
			(ordering == "natural") ? (
				(mod(i, 2) == 0) ? "reversed" : "sequential"
			  ) : "random";
			use_batchnorm=bn,
			lastzero=init_I,
			seed=rand(UInt))
		for i in 1:nflows]...), MvNormal(idim, 1.0f0)
	) # seed has to be passed into maf in order to create the same masks

	# reset seed
	(init_seed != nothing) ? Random.seed!() : nothing

	model
end

(maf::MAF)(X) = maf.flows(X)
Flux.trainable(maf::MAF) = (maf.flows, )

function Base.show(io::IO, maf::MAF)
	# to avoid the show explosion
	print(io, "MAF(flows=$(length(maf.flows)), idim=$(length(maf.base)))")
end

function loss(model::F, X) where {F <: TabularFlow}
	Z, logJ = model((X, _init_logJ(X)))
	-sum(logpdf(model.base, Z)' .+ logJ)/size(X, 2)
end

function Distributions.logpdf(model::F, X) where {F <: TabularFlow}
	Z, logJ = model((X, _init_logJ(X)))
	logpdf(model.base, Z)' .+ logJ
end

function StatsBase.fit!(model::F, data::Tuple; max_train_time=82800,
						batchsize=64, patience=200, check_interval::Int=10,
						wreg::Float32=1f-6, lr::Float32=1f-4, quantile=(0.0, 1.0),
						kwargs...) where F <: TabularFlow
	# add regularization through weight decay in optimizer
	opt = (wreg > 0) ? ADAMW(lr, (0.9, 0.999), wreg) : Flux.ADAM(lr)

	trn_model = deepcopy(model)
	ps = Flux.params(trn_model);

	X = data[1][1]
	# filter only normal data from validation set
	X_val = data[2][1][:, data[2][2] .== 0.0f0]

	history = MVHistory()
	_patience = patience

	best_val_loss = loss(trn_model, X_val)
	i = 1
	start_time = time()
	for batch in RandomBatches(X, batchsize)
		l = 0.0f0
		q_batch = lkl_quantile(trn_model, batch, quantile)
		gs = gradient(() -> begin l = loss(trn_model, q_batch) end, ps)
		Flux.update!(opt, ps, gs)

		# validation/early stopping
		testmode!(model, true)
		val_loss = loss(trn_model, X_val)
		testmode!(model, false)
		@info "$i - loss: $l (batch) | $val_loss (validation)"

		if isnan(val_loss) || isinf(val_loss) || isnan(l) || isinf(l)
			error("Encountered invalid values in loss function.")
		end

		push!(history, :training_loss, i, l)
		push!(history, :validation_likelihood, i, val_loss)

		# time limit for training
		if time() - start_time > max_train_time
			@info "Stopped training after $(i) iterations due to time limit."
			model = deepcopy(trn_model)
			break
		end

		if val_loss < best_val_loss
			best_val_loss = val_loss
			_patience = patience

			# this should save the model at least once
			# when the validation loss is decreasing
			if mod(i, 10) == 0
				model = deepcopy(trn_model)
			end
		else
			_patience -= 1
			if _patience == 0
				@info "Stopped training after $(i) iterations."
				break
			end
		end
		i += 1
	end

	# calling loss in trainmode allows to set BatchNorm
	# statistics from the whole training dataset
	trainmode!(model, true)
	loss(model, X)

	# returning model in this way is not ideal
	# it would have to modify the reference the
	# underlying structure
	(history=history, niter=i, model=model, npars=sum(map(p->length(p), ps)))
end

function StatsBase.predict(model::F, X) where {F <: TabularFlow}
	testmode!(model, true)
	Z, logJ = model((X, _init_logJ(X)))
	testmode!(model, false)
	-(logpdf(model.base, Z)' .+ logJ)[:]
end
