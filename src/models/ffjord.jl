using Flux
using StatsBase
using Statistics
using Distributions
using DistributionsAD
using FfjordFlow
using ValueHistories
using MLDataPattern

struct FFJORD
    m
end

log_normal(x::AbstractVector) = - sum(x.^2) / 2 - length(x)*log(2π) / 2
log_normal(x) = -0.5f0 .* sum(x.^2, dims = 1) .- (size(x,1)*log(Float32(2π)) / 2)

Flux.@functor FFJORD

function FFJORD(;idim::Int=1, activation=tanh, nhidden::Int=1,
                size_hidden::Int=5, nblocks::Int=1, init_seed=nothing, kwargs...)
    # if seed is given, set it
    (init_seed != nothing) ? Random.seed!(init_seed) : nothing

    mm = []
    for i in 1:nblocks
        d1 = Dense(idim, idim*size_hidden, activation)
        dd = tuple([Dense(idim*size_hidden, idim*size_hidden, activation) for j in 1:nhidden]...;)
        d2 = Dense(idim*size_hidden, idim)
        m = Ffjord(Chain(d1, dd..., d2), (0.0, 1.0))
        push!(mm, m)
    end

    # reset seed
	(init_seed != nothing) ? Random.seed!() : nothing

    FFJORD(mm)
end

function Base.show(io::IO, ffjord::FFJORD)
    # to avoid the show explosion
	print(io, "FFJORD(...)")
end

function Distributions.logpdf(model::FFJORD, x)
    m = model.m
    n = length(m)
    logdet = zeros(1, size(x, 2))
    for i in 1:n
	       x, _logdet = m[i]((x, 0.0))
           logdet += _logdet
    end
    return vec(log_normal(x) + logdet)
end

function StatsBase.predict(model::FFJORD, x)
    m = model.m
    n = length(m)
    logdet = zeros(1, size(x, 2))
    for i in 1:n
	       x, _logdet = Cnf(m[i])((x, 0.0))
           logdet += _logdet
    end
    return -vec(log_normal(x) + logdet)
end

bbatchlogpdf(m::FFJORD, x, bs::Int) = reduce(vcat, map(i -> logpdf(m, x[:,i]), Iterators.partition(1:size(x,2), bs)))

function StatsBase.fit!(model::FFJORD, data::Tuple; max_train_time=82800,
						batchsize=64, patience=20, check_interval::Int=10,
						quantile=(0.0, 1.0), kwargs...)
	opt = ADAM()
	history = MVHistory()
	tr_model = deepcopy(model)
	ps = Flux.params(tr_model)
	_patience = patience

	# split data
	tr_x = data[1][1]
	val_x = data[2][1][:, data[2][2] .== 0]

	best_val_loss = Inf
	i = 1
	start_time = time()
	frmt = (v) -> round(v, digits=4)
	for batch in RandomBatches(tr_x, batchsize)
		# batch loss
		batch_loss = 0f0
		grad_time = @elapsed begin
			gs = gradient(() -> begin
				q_batch = lkl_quantile(tr_model, batch, quantile)
				batch_loss = -mean(logpdf(tr_model, q_batch))
			end, ps)
			Flux.update!(opt, ps, gs)
		end

		push!(history, :training_loss, i, batch_loss)
		push!(history, :grad_time, i, grad_time)

		# validation/early stopping
		if (i%check_interval == 0)
			val_lkl_time = @elapsed val_loss = -mean(bbatchlogpdf(tr_model, val_x, batchsize))
			@info "$i - loss: $(frmt(batch_loss)) (batch) | $(frmt(val_loss)) (validation) || $(frmt(grad_time)) (t_grad) | $(frmt(val_lkl_time)) (t_val)"

			if isnan(val_loss) || isnan(batch_loss)
				error("Encountered invalid values in loss function.")
			end

			push!(history, :validation_likelihood, i, val_loss)
			push!(history, :val_lkl_time, i, val_lkl_time)

			if val_loss < best_val_loss
				best_val_loss = val_loss
				_patience = patience

				model = deepcopy(tr_model)
			else # else stop if the model has not improved for `patience` iterations
				_patience -= 1
				if _patience == 0
					@info "Stopped training after $(i) iterations, $((time() - start_time)/3600) hours."
					break
				end
			end
		end

		if time() - start_time > max_train_time # stop early if time is running out
			model = deepcopy(tr_model)
			@info "Stopped training after $(i) iterations, $((time() - start_time)/3600) hours due to time constraints."
			break
		end

		i += 1
	end

	(history=history, iterations=i, model=model, npars=sum(map(p -> length(p), ps)))
end
