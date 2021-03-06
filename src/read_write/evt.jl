#######################################
#
# evt file
#
#######################################

@doc """
Read *.evt file and convert to form for EEG.jl
""" ->
function read_evt(fname::AbstractString, fs::Number; kwargs...)
    Logging.info("Reading evt file: $fname")

    d = readdlm(fname)

    if size(d,2) > 3
        warn("EVT file has too many columns")
    end

    d = Dict(d[1,1] => d[2:end, 1], d[1,2] => d[2:end, 2], d[1,3] => d[2:end, 3])

    if haskey(d, "Tmu")
        d["Index"] = [1 + round(i * (1 / 1000000) * float(fs)) for i in d["Tmu"]]
    elseif haskey(d, "Tsec")
        d["Index"] = [1 + round(i  * float(fs)) for i in d["Tsec"]]
    else
        warn("Unknown time scale in evt file")
    end

    d["Duration"] = ones(length(d["Code"]))

    Logging.info("Imported $(length(d["Code"])) events")

    return Dict("Code" => d["Code"] + 252, "Index" => d["Index"], "Duration" => d["Duration"])
end
