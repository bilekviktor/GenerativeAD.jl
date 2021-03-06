using Flux
using ConditionalDists
using GenerativeModels
import GenerativeModels: GAN
using ValueHistories
using MLDataPattern: RandomBatches
using Distributions
using DistributionsAD
using StatsBase
using Random

"""
	gan_constructor(;idim::Int=1, zdim::Int=1, activation="relu", hdim=128, nlayers::Int=3, 
		init_seed=nothing, kwargs...)

Constructs a generative adversarial net.

# Arguments
	- `idim::Int`: input dimension.
	- `zdim::Int`: latent space dimension.
	- `activation::String="relu"`: activation function.
	- `hdim::Int=128`: size of hidden dimension.
	- `nlayers::Int=3`: number of generator/discriminator layers, must be >= 2. 
	- `init_seed=nothing`: seed to initialize weights.
	- `last_linear=false`: is output of discriminator linear?
"""
function gan_constructor(;idim::Int=1, zdim::Int=1, activation = "relu", hdim=128, nlayers::Int=2, 
	init_seed=nothing, last_linear=false, kwargs...)
	(nlayers < 2) ? error("Less than 3 layers are not supported") : nothing
	
	# if seed is given, set it
	(init_seed != nothing) ? Random.seed!(init_seed) : nothing
	
	# construct the model
	# generator
	generator_map = build_mlp(zdim, hdim, idim, nlayers, activation=activation)
	generator = ConditionalMvNormal(generator_map)
	
	# discriminator
	lastlayer = last_linear ? "linear" : "σ"
	discriminator_map = build_mlp(idim, hdim, 1, nlayers, activation=activation, lastlayer=lastlayer)
	discriminator = ConditionalMvNormal(discriminator_map)

	# reset seed
	(init_seed != nothing) ? Random.seed!() : nothing

	# constructor form GenerativeModels.jl
	model = GAN(zdim, generator, discriminator)
end

"""
	conv_gan_constructor(idim=(2,2,1), zdim::Int=1, activation="relu", hdim=1024, kernelsizes=(1,1), 
		channels=(1,1), scalings=(1,1), init_seed=nothing, batchnorm=false, kwargs...)

Constructs a convolutional GAN.

# Arguments
	- `idim::Int`: input dimension.
	- `zdim::Int`: latent space dimension.
	- `activation::String="relu"`: activation function.
	- `hdim::Int=1024`: size of hidden dimension.
	- `kernelsizes=(1,1)`: kernelsizes in consequent layers.
	- `channels=(1,1)`: number of channels.
	- `scalings=(1,1)`: scalings in subsequent layers.
	- `init_seed=nothing`: seed to initialize weights.
	- `batchnorm=false`: use batchnorm (discouraged). 
"""
function conv_gan_constructor(;idim=(2,2,1), zdim::Int=1, activation="relu", hdim=1024, 
	kernelsizes=(1,1), channels=(1,1), scalings=(1,1),
	init_seed=nothing,	batchnorm=false, kwargs...)
	# if seed is given, set it
	(init_seed != nothing) ? Random.seed!(init_seed) : nothing
	
	# construct the model
	# generator
	generator_map = conv_decoder(idim, zdim, reverse(kernelsizes), reverse(channels), 
		reverse(scalings); activation=activation, batchnorm=batchnorm)
	generator = ConditionalMvNormal(generator_map)
	
	# decoder - we will optimize only a shared scalar variance for all dimensions
	# also, the decoder output will be vectorized so the usual logpdfs vcan be used
	vecdim = reduce(*,idim[1:3]) # size of vectorized data
	discriminator_map = Chain(conv_encoder(idim, 1, kernelsizes, channels, scalings,
			activation=activation, batchnorm=batchnorm)..., x->σ.(x))
	discriminator = ConditionalMvNormal(discriminator_map)

	# reset seed
	(init_seed != nothing) ? Random.seed!() : nothing

	# get the vanilla VAE
	model = GAN(zdim, generator, discriminator)
end

"""
	StatsBase.fit!(model::GenerativeModels.GAN, data::Tuple, gloss:Function, dloss::Function; 
		max_iter=10000, max_train_time=82800, lr=0.001, batchsize=64, patience=30, check_interval::Int=10, 
		weight_clip=nothing, discriminator_advantage::Int=1, stop_threshold=0.01, usegpu=false,
		kwargs...)
"""
function StatsBase.fit!(model::GenerativeModels.GAN, data::Tuple, gloss::Function, dloss::Function; 
	max_iters=10000, max_train_time=82800, lr=0.001, batchsize=64, patience=30, check_interval::Int=10, 
	weight_clip=nothing, discriminator_advantage::Int=1, stop_threshold=0.01, usegpu=false,
	kwargs...)
	history = MVHistory()
	dopt = RMSProp(lr)
	gopt = RMSProp(lr)

	tr_model = deepcopy(model)
	dps = Flux.params(tr_model.discriminator)
	gps = Flux.params(tr_model.generator)
	_patience = patience

	tr_x = data[1][1]
	if ndims(tr_x) == 2
		val_x = data[2][1][:,data[2][2] .== 0]
	elseif ndims(tr_x) == 4
		val_x = data[2][1][:,:,:,data[2][2] .== 0]
	else
		error("not implemented for other than 2D and 4D data")
	end
	val_N = size(val_x,2)

	# on large datasets, batching loss is faster
	best_val_dloss = Inf
	best_val_gloss = Inf
	i = 1
	start_time = time() # end the training loop after 23hrs
	for xbatch in RandomBatches(tr_x, batchsize)
		xbatch = usegpu ? gpu(Array(xbatch)) : xbatch
		# disc loss
		batch_dloss = 0f0
		# some recommend training the discriminator mupltiple times
		for n in 1:discriminator_advantage
			gs = gradient(() -> begin 
				batch_dloss = dloss(tr_model,xbatch)
			end, dps)
		 	Flux.update!(dopt, dps, gs)

		 	# clip weights of discriminator - needed for wgan
		 	(weight_clip != nothing) ? clip_weights!(dps, weight_clip) : nothing
		end

	 	# gen loss
		batch_gloss = 0f0
		gs = gradient(() -> begin 
			batch_gloss = gloss(tr_model,xbatch)
		end, gps)
		Flux.update!(gopt, gps, gs)
		 
		push!(history, :training_dloss, i, batch_dloss)
		push!(history, :training_gloss, i, batch_gloss)

		if mod(i, check_interval) == 0
			
			# validation/early stopping
			val_dloss = (val_N > 5000) ? dloss(tr_model, val_x, 256) : dloss(tr_model, val_x)
			val_gloss = (val_N > 5000) ? gloss(tr_model, val_x, 256) : gloss(tr_model, val_x)
			
			@info "$i - dloss: $(batch_dloss) | $(val_dloss) (validation)"
			@info "$i - gloss: $(batch_gloss) | $(val_gloss) (validation)"
				
			if isnan(val_gloss) || isnan(batch_dloss) || isnan(val_dloss) || isnan(batch_gloss)
				error("Encountered invalid values in loss function.")
			end

			push!(history, :validation_dloss, i, val_dloss)
			push!(history, :validation_gloss, i, val_gloss)
			
			if val_dloss > stop_threshold
				best_val_dloss = val_dloss
				_patience = patience

				# this should save the model at least once
				# when the validation loss is decreasing 
				model = deepcopy(tr_model)
			else # else stop if the model has not improved for `patience` iterations
				_patience -= 1
				if _patience == 0
					@info "Stopped training after $(i) iterations."
					break
				end
			end
		end
		if (time() - start_time > max_train_time) | (i > max_iters) # stop early if time is running out
			model = deepcopy(tr_model)
			@info "Stopped training after $(i) iterations, $((time() - start_time)/3600) hours."
			break
		end
		i += 1
	end
	# again, this is not optimal, the model should be passed by reference and only the reference should be edited
	(history=history, iterations=i, model=model, npars=sum(map(p->length(p), Flux.params(model))))
end

"""
	dloss(model::GenerativeModels.GAN,x[,batchsize])

Classical discriminator loss of the GAN model.
"""
dloss(m::GenerativeModels.GAN,x) = 
	dloss(m.discriminator.mapping,m.generator.mapping,x,rand(m.prior,size(x,ndims(x))))
dloss(m::GenerativeModels.GAN,x,batchsize::Int) = 
	mean(map(y->dloss(m,y), Flux.Data.DataLoader(x, batchsize=batchsize)))

"""
	gloss(model::GenerativeModels.GAN,x[,batchsize])

Classical generator loss of the GAN model.
"""
gloss(m::GenerativeModels.GAN,x) = 
	gloss(m.discriminator.mapping,m.generator.mapping,rand(m.prior,size(x,ndims(x))))
gloss(m::GenerativeModels.GAN,x,batchsize::Int) = 
	mean(map(y->gloss(m,y), Flux.Data.DataLoader(x, batchsize=batchsize)))

"""
	fmloss(model,x[,batchsize])

Feature-matching loss matches the output of the penultimate layer of the discriminator on 
real and fake data.
"""
function fmloss(m::GenerativeModels.GAN,x)
	z = rand(m.prior, size(x,ndims(x)))
	h = m.discriminator.mapping[1:end-1]
	hx = h(x)
	hz = h(m.generator.mapping(z))
	Flux.mse(hx, hz)
end
fmloss(m::GenerativeModels.GAN,x,batchsize::Int) = 
	mean(map(y->fmloss(m,y), Flux.Data.DataLoader(x, batchsize=batchsize)))
		
"""
	generate(model::GenerativeModels.GAN, N::Int)

Generate novel samples.
"""
generate(m::GenerativeModels.GAN, N::Int) = m.generator.mapping(rand(m.prior, N))

"""
	discriminate(model::GenerativeModels.GAN, x)

Discriminate the input - lower score belongs to samples not coming from training distribution.
"""
discriminate(m::GenerativeModels.GAN, x) = m.discriminator.mapping(x)
