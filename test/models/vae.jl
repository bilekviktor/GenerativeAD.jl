@testset "VAE" begin
	using DrWatson
	@quickactivate
	using Test
	using GenerativeAD
	import StatsBase: fit!, predict
	using ConditionalDists, GenerativeModels, Distributions
	using EvalMetrics
	using IPMeasures
	using Flux

	# toy example
	M = 4
	N1 = 100
	N2 = 50
	X = vcat(randn(Float32, Int(M/2), N1), ones(Float32, Int(M/2), N1))
	Y = vcat(randn(Float32, Int(M/2), N2), ones(Float32, Int(M/2), N2))
	Z = vcat(ones(Float32, Int(M/2), N2), randn(Float32, Int(M/2), N2))
	data = ((X,),(Y,zeros(size(Y,2))))
	parameters = (zdim=8, hdim=32, lr=0.001, batchsize=8, activation="swish", nlayers=3, idim=M)
	function basic_convergence_test(model, loss)
		history, iterations, model = fit!(model, data, loss; patience = 100, max_train_time=600, parameters...)
		scores = map(x->GenerativeAD.Models.reconstruction_score(model, x), (X,Y,Z))
		@test mean(scores[1]) < mean(scores[3])
		@test mean(scores[2]) < mean(scores[3])
		model
	end
	# vanilla VAE
	model = GenerativeAD.Models.vae_constructor(;parameters...)
	loss(model::GenerativeModels.VAE, x) = -elbo(model, x)
	basic_convergence_test(model, loss)
	# vanilla WAE
	model = GenerativeAD.Models.vae_constructor(;parameters...)
	k = IMQKernel(0.1f0)
	loss(model::GenerativeModels.VAE, x) = 
		mmd_mean(model, x, k) .- mean(logpdf(model.decoder, x, rand(model.encoder, x)))
	basic_convergence_test(model, loss)
	# VAMP WAE
	k = 4
	pseudoinput_mean = mean(X, dims=ndims(X))
	parameters = (zdim=8, hdim=32, lr=0.001, batchsize=8, activation="swish", nlayers=3, idim=M, 
		prior="vamp", pseudoinput_mean=pseudoinput_mean,k=k)
	model = GenerativeAD.Models.vae_constructor(;parameters...)
	k = IMQKernel(0.1f0)
	loss(model::GenerativeModels.VAE, x) = 
		mmd_mean(model, x, k) .- mean(logpdf(model.decoder, x, rand(model.encoder, x)))
	basic_convergence_test(model, loss)

	# iris test
	# vanilla VAE
	data = GenerativeAD.load_data("iris")
	include(joinpath(pathof(GenerativeAD), "../../scripts/experiments_tabular/vae.jl"))
	parameters = (zdim=2, hdim=32, lr=0.001, batchsize=32, activation="relu", nlayers=3)
	edited_parameters = GenerativeAD.edit_params(data, parameters)
	training_info, sfs_params = fit(data, edited_parameters)
	save_entries = merge(training_info, (model=nothing,))
	results = map(res->GenerativeAD.experiment(res..., data, ""; save_result=false, save_entries...), sfs_params)
	@info "VAE iris test"
	for result in results
		println(result[:parameters])
		println("validation auc = ", au_roccurve(result[:val_labels], result[:val_scores]))
		println("test auc = ", au_roccurve(result[:tst_labels], result[:tst_scores]))
	end
end
