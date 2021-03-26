using Plots
using ArgParse
using DrWatson
@quickactivate
using CSV
using BSON
using Random
using FileIO
using DataFrames

# s = datadir("evaluation/zkouska_graf_rel_params.bson")

plotly()
function plot_npar_rank(s)
    f = load(s)
    df = f[:df]
    pl = plot()
    for n in unique(df[:modelname])
        n_df = df[df[:modelname] .== n, :]
        plot!(n_df[:relnpars], n_df[:rank], label = n)
    end
    display(pl)
    return pl
end
