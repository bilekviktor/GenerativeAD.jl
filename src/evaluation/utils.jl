using Base.Threads: @threads

function collect_files!(target::String, files)
	if isfile(target)
		push!(files, target)
	else
		for file in readdir(target, join=true)
			collect_files!(file, files)
		end
	end
	files
end


"""
	collect_files(target)

Walks recursively the `target` directory, collecting all files only along the way.
"""
collect_files(target) = collect_files!(target, String[])


"""
	collect_files_th(target)

Multithreaded version of recursive file collection.
Does not have as many checks as th single threaded.
May not perform as well on some configurations.
Using @threads inside recursion may not be the best idea.
"""
function collect_files_th(target::String)
    files = readdir(target, join=true)
    if all(isfile.(files))
        println(target)
        return files
    end
    results = Vector{Vector{String}}(undef, length(files))
    @threads for i in 1:length(files)
        results[i] = collect_files_th(files[i])
    end
    reduce(vcat, results)
end

function quantile_scores(score, percentage=(0.0, 1.0))
	n = length(score)
    l, r = percentage
    if l <= 0.0
        lq = 1
    else
        lq = Int(ceil(l*n))
    end
    if r >= 1.0
        rq = n
    else
        rq = Int(ceil(r*n))
    end
    perms = sortperm(score)
    indxs = perms[lq:rq]
	return score[indxs]
end
