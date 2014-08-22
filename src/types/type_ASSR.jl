using BDF
using DataFrames
using MAT


type ASSR
    data::Array
    triggers::Dict                 #TODO: Change to events
    sample_rate::Number
    modulation_frequency::Number
    reference_channel::String      # TODO: Change to array
    file_path::String
    file_name::String
    system_code_channel            # Used when re writing data to disk. TODO: Make function to generate
    trigger_channel                # Used when re writing data to disk. TODO: Make function to generate
    header::Dict                   # Try not to use. Keep for completeness
    processing::Dict               # Store processes run on the data
    #TODO Channels as array of stings?
end


#######################################
#
# Read ASSR
#
#######################################

function read_ASSR(fname::Union(String, IO); kwargs...)

    info("Importing file $fname")

    if isa(fname, String)
        file_path, file_name, ext = fileparts(fname)
        debug("Importing file for ASSR processing")
    else
        warn("Filetype is IO. Might be bugged")
        file_path = "IO"
        file_name = fname
        ext = "IO"
    end

    #
    # Import raw data

    if ext == "bdf"
        data, triggers, sample_rate, reference_channel, system_code_channel, trigger_channel, header = import_biosemi(fname)
    else
        warn("File type $ext is unknown")
    end

    #
    # Import information files in the same directory

    mat_path = string(file_path, file_name, ".mat")
    if isreadable(mat_path)
        rba                  = matread(mat_path)
        modulation_frequency = rba["properties"]["stimulation_properties"]["stimulus_1"]["rounded_modulation_frequency"]
        info("Imported matching .mat file")
    else
        modulation_frequency = NaN
    end

    #
    # Create ASSR type

    # Place in type
    a = ASSR(data, triggers, sample_rate, modulation_frequency, reference_channel, file_path, file_name,
             system_code_channel, trigger_channel, header, Dict())

    #
    # Clean the data

    # Remove status channel information
    remove_channel!(a, "Status")

    # Tidy channel names if required
    if a.header["chanLabels"][1] == "A1"
        debug("  Converting names from BIOSEMI to 10-20")
        a.header["chanLabels"] = channelNames_biosemi_1020(a.header["chanLabels"])
    end

    # Clean epoch index
    a = _clean_epoch_index(a; kwargs...)


    return a
end


function _clean_epoch_index(a::ASSR; valid_indices::Array{Int}=[1, 2],
                            min_epoch_length::Int=0, max_epoch_length::Number=Inf,
                            remove_first::Int=0,     max_epochs::Number=Inf, kwargs...)

    info("Cleaning trigger information")

    # Make in to data frame for easy management
    epochIndex = DataFrame(Code = a.triggers["code"], Index = a.triggers["idx"]);
    epochIndex[:Code] = epochIndex[:Code] - 252

    # Check for not valid indices and throw a warning
    if sum([in(i, [0, valid_indices]) for i = epochIndex[:Code]]) != length(epochIndex[:Code])
        non_valid = !convert(Array{Bool}, [in(i, [0, valid_indices]) for i = epochIndex[:Code]])
        non_valid = sort(unique(epochIndex[:Code][non_valid]))
        warn("File contains non valid triggers: $non_valid")
    end
    # Just take valid indices
    valid = convert(Array{Bool}, vec([in(i, valid_indices) for i = epochIndex[:Code]]))
    epochIndex = epochIndex[ valid , : ]

    # Trim values if requested
    if remove_first > 0
        epochIndex = epochIndex[remove_first+1:end,:]
        info("Trimming first $remove_first triggers")
    end
    if max_epochs < Inf
        epochIndex = epochIndex[1:minimum([max_epochs, length(epochIndex[:Index])]),:]
        info("Trimming to $max_epochs triggers")
    end

    # Throw out epochs that are the wrong length
    epochIndex[:Length] = [0, diff(epochIndex[:Index])]
    if min_epoch_length > 0
        epochIndex[:valid_length] = epochIndex[:Length] .> min_epoch_length
        num_non_valid = sum(!epochIndex[:valid_length])
        if num_non_valid > 1    # Don't count the first trigger
            warn("Removed $num_non_valid triggers < length $min_epoch_length")
            epochIndex = epochIndex[epochIndex[:valid_length], :]
        end
    end
    epochIndex[:Length] = [0, diff(epochIndex[:Index])]
    if max_epoch_length < Inf
        epochIndex[:valid_length] = epochIndex[:Length] .< max_epoch_length
        num_non_valid = sum(!epochIndex[:valid_length])
        if num_non_valid > 0
            warn("Removed $num_non_valid triggers > length $max_epoch_length")
            epochIndex = epochIndex[epochIndex[:valid_length], :]
        end
    end

    # Sanity check
    if std(epochIndex[:Length][2:end]) > 1
        warn("Your epoch lengths vary too much")
        warn(string("Length: median=$(median(epochIndex[:Length][2:end])) sd=$(std(epochIndex[:Length][2:end])) ",
              "min=$(minimum(epochIndex[:Length][2:end]))"))
        debug(epochIndex)
    end

    a.triggers = ["idx" => vec(int(epochIndex[:Index])'), "code" => vec(epochIndex[:Code] .+ 252)]

    return a
end
#######################################
#
# Modify ASSR
#
#######################################

function add_channel(a::ASSR, data::Array, chanLabels::ASCIIString;
                     sampRate::Number=a.header["sampRate"][1],     scaleFactor::Number=a.header["scaleFactor"][1],
                     physMin::Number=a.header["physMin"][1],       physMax::Number=a.header["physMax"][1],
                     digMin::Number=a.header["digMin"][1],         digMax::Number=a.header["digMax"][1],
                     nSampRec::Number=a.header["nSampRec"][1],     prefilt::String=a.header["prefilt"][1],
                     reserved::String=a.header["reserved"][1],     physDim::String=a.header["physDim"][1],
                     transducer::String=a.header["transducer"][1])

    info("Adding channel $chanLabels")

    a.data = hcat(a.data, data)

    push!(a.header["sampRate"],    sampRate)
    push!(a.header["physMin"],     physMin)
    push!(a.header["physMax"],     physMax)
    push!(a.header["digMax"],      digMax)
    push!(a.header["digMin"],      digMin)
    push!(a.header["nSampRec"],    nSampRec)
    push!(a.header["scaleFactor"], scaleFactor)

    push!(a.header["prefilt"],    prefilt)
    push!(a.header["reserved"],   reserved)
    push!(a.header["chanLabels"], chanLabels)
    push!(a.header["transducer"], transducer)
    push!(a.header["physDim"],    physDim)

    return a
end


function remove_channel!(a::ASSR, channel_idx::Array{Int})

    channel_idx = channel_idx[channel_idx .!= 0]

    info("Removing channel(s) $channel_idx")

    keep_idx = [1:size(a.data)[end]]
    for c = sort(channel_idx, rev=true)
        try
            splice!(keep_idx, c)
        end
    end

    a.data = a.data[:, keep_idx]

    # Remove header info
    for key = ["sampRate", "physMin", "physMax", "nSampRec", "prefilt", "reserved", "chanLabels", "transducer",
               "physDim", "digMax", "digMin", "scaleFactor"]
        a.header[key]    = a.header[key][keep_idx]
    end
end

function remove_channel!(a::ASSR, channel_names::Array{ASCIIString})

    info("Removing channel(s) $(append_strings(channel_names))")

    remove_channel!(a, int([findfirst(a.header["chanLabels"], c) for c=channel_names]))
end

function remove_channel!(a::ASSR, channel_name::Union(String, Int))
    remove_channel!(a, [channel_name])
end


function trim_ASSR(a::ASSR, stop::Int; start::Int=1)

    info("Trimming $(size(a.data)[end]) channels between $start and $stop")

    a.data = a.data[start:stop,:]
    a.system_code_channel = a.system_code_channel[start:stop]
    a.trigger_channel = a.trigger_channel[start:stop]


    to_keep = find(a.triggers["idx"] .<= stop)
    a.triggers["idx"]  = a.triggers["idx"][to_keep]
    #=a.triggers["dur"]  = a.triggers["dur"][to_keep]=#
    a.triggers["code"] = a.triggers["code"][to_keep]

    return a
end


#######################################
#
# Merge channels
#
#######################################

function merge_channels(a::ASSR, merge_Chans::Array{ASCIIString}, new_name::String)

    debug("Total origin channels: $(length(a.header["chanLabels"]))")

    keep_idxs = [findfirst(a.header["chanLabels"], i) for i = merge_Chans]
    keep_idxs = int(keep_idxs)

    if sum(keep_idxs .== 0) > 0
        warn("Could not merge channels as don't exist: $(append_strings(vec(merge_Chans[keep_idxs .== 0])))")
        keep_idxs = keep_idxs[keep_idxs .> 0]
    end

    info("Merging channels $(append_strings(vec(a.header["chanLabels"][keep_idxs,:])))")
    debug("Merging channels $keep_idxs")

    a = add_channel(a, mean(a.data[:,keep_idxs], 2), new_name)
end


#######################################
#
# Filtering
#
#######################################


function highpass_filter(a::ASSR; cutOff::Number=2, order::Int=3, tolerance::Number=0.01)

    a.data, f = highpass_filter(a.data, cutOff=cutOff, order=order, fs=a.header["sampRate"][1])

    _filter_check(f, a.modulation_frequency, a.header["sampRate"][1], tolerance)

    return _append_filter(a, f)
 end


function lowpass_filter(a::ASSR; cutOff::Number=150, order::Int=3, tolerance::Number=0.01)

    a.data, f = lowpass_filter(a.data, cutOff=cutOff, order=order, fs=a.header["sampRate"][1])

    _filter_check(f, a.modulation_frequency, a.header["sampRate"][1], tolerance)

    return _append_filter(a, f)
 end


function _filter_check(f::Filter, mod_freq::Number, fs::Number, tolerance::Number)
    #
    # Ensure that the filter does not alter the modulation frequency greater than a set tolerance
    #

    mod_change = abs(freqz(f, mod_freq, fs))
    if mod_change > 1 + tolerance || mod_change < 1 - tolerance
        warn("Filtering has modified modulation frequency greater than set tolerance: $mod_change")
    end
    debug("Filter magnitude at modulation frequency: $(mod_change)")
end


function _append_filter(a::ASSR, f::Filter; name::String="filter")
    #
    # Put the filter information in the ASSR processing structure
    #

    key_name = new_processing_key(a.processing, "filter")
    merge!(a.processing, [key_name => f])

    return a
end


#######################################
#
# filtering
#
#######################################

function rereference(a::ASSR, refChan)

    a.data = rereference(a.data, refChan, a.header["chanLabels"])

    if isa(refChan, Array)
        refChan = append_strings(refChan)
    end

    a.reference_channel = refChan

    return a
end


#######################################
#
# Add triggers for more epochs
#
#######################################


function add_triggers(a::ASSR; kwargs...)

    debug("Adding triggers to reduce ASSR. Using ASSR modulation frequency")

    add_triggers(a, a.modulation_frequency; kwargs...)
end


function add_triggers(a::ASSR, mod_freq::Number; kwargs...)

    debug("Adding triggers to reduce ASSR. Using $(mod_freq)Hz")

    epochIndex = DataFrame(Code = a.triggers["code"], Index = a.triggers["idx"]);
    epochIndex[:Code] = epochIndex[:Code] - 252

    add_triggers(a, mod_freq, epochIndex; kwargs...)
end


function add_triggers(a::ASSR, mod_freq::Number, epochIndex; cycle_per_epoch::Int=1, args...)

    info("Adding triggers to reduce ASSR. Reducing $(mod_freq)Hz to $cycle_per_epoch cycle(s).")

    # Existing epochs
    existing_epoch_length   = maximum(diff(epochIndex[:Index]))     # samples
    existing_epoch_length_s = existing_epoch_length / a.header["sampRate"][1]
    debug("Existing epoch length: $(existing_epoch_length_s)s")

    # New epochs
    new_epoch_length_s = cycle_per_epoch / mod_freq
    new_epochs_num     = round(existing_epoch_length_s / new_epoch_length_s) - 2
    new_epoch_times    = [1:new_epochs_num]*new_epoch_length_s
    new_epoch_indx     = [0, round(new_epoch_times * a.header["sampRate"][1])]
    debug("New epoch length = $new_epoch_length_s")
    debug("New # epochs     = $new_epochs_num")

    # Place new epoch indices
    debug("Was $(length(epochIndex[:Index])) indices")
    new_indx = epochIndex[:Index][1:end-1] .+ new_epoch_indx'
    new_indx = reshape(new_indx', length(new_indx), 1)[1:end-1]
    debug("Now $(length(new_indx)) indices")

    # Place in dict
    # Will wipe old info
    new_code = int(ones(1, length(new_indx))) .+ 252
    a.triggers = ["idx" => vec(int(new_indx)'), "code" => vec(new_code)]

    return a
end



#######################################
#
# Extract epochs
#
#######################################

function extract_epochs(a::ASSR)

    merge!(a.processing, ["epochs" => extract_epochs(a.data, a.triggers)])

    return a
end


function create_sweeps(a::ASSR; epochsPerSweep::Int=4)

    merge!(a.processing, ["sweeps" => create_sweeps(a.processing["epochs"], epochsPerSweep = epochsPerSweep)])

    return a
end


function write_ASSR(a::ASSR, fname::String)

    info("Saving $(size(a.data)[end]) channels to $fname")

    writeBDF(fname, a.data', a.trigger_channel, a.system_code_channel, a.header["sampRate"][1],
        startDate=a.header["startDate"], startTime=a.header["startTime"],
        chanLabels=a.header["chanLabels"] )

end


#######################################
#
# Statistics
#
#######################################

function ftest(a::ASSR; side_freq::Number=2, subject::String="Unknown")

    ftest(a, a.modulation_frequency,   side_freq=side_freq, subject=subject)
end

function ftest(a::ASSR, freq_of_interest::Number; side_freq::Number=2, subject::String="Unknown")

    # Extract required information
    fs = a.header["sampRate"][1]

    # TODO: Account for multiple applied filters
    if haskey(a.processing, "filter1")
        used_filter = a.processing["filter1"]
    else
        used_filter = nothing
    end

    info("Calculating F statistic on $(size(a.data)[end]) channels at $freq_of_interest Hz +-$(side_freq) Hz")

    snrDb, signal, noise, statistic = ftest(a.processing["sweeps"], freq_of_interest, fs,
                                            side_freq = side_freq, used_filter = used_filter)

    result = DataFrame(
                        Electrode = copy(a.header["chanLabels"]),
                        SignalPower = vec(signal),
                        NoisePower = vec(noise),
                        SNR = vec(10.^(snrDb/10)),
                        SNRdB = vec(snrDb),
                        Statistic = vec(statistic),
                        Significant = vec(statistic.<0.05),
                        Subject = subject,
                        Analysis="ftest",
                        NoiseHz = side_freq,
                        Frequency = freq_of_interest,
                        ModulationFrequency = copy(a.modulation_frequency),
                        )

    key_name = new_processing_key(a.processing, "ftest")
    merge!(a.processing, [key_name => result])

    return a
end

function ftest(a::ASSR, freq_of_interest::Array; side_freq::Number=2, subject::String="Unknown")

    for f = freq_of_interest
        a = ftest(a, f, side_freq=side_freq, subject=subject)
    end
    return a
end


function save_results(a::ASSR; name_extension::String="")

    file_name = string(a.file_name, name_extension, ".csv")

    # Rename to save space
    results = a.processing

    # Index of keys to be exported
    result_idx = find_keys_containing(results, "ftest")

    if length(result_idx) > 0

        to_save = get(results, collect(keys(results))[result_idx[1]], 0)

        if length(result_idx) > 1
            for k = result_idx[2:end]
                result_data = get(results, collect(keys(results))[k], 0)
                to_save = rbind(to_save, result_data)
            end
        end

    writetable(file_name, to_save)
    end

    info("File saved to $file_name")

    return a
end

#######################################
#
# Helper functions
#
#######################################


function assr_frequency(rounded_freq::Number; stimulation_sample_rate::Number=32000,
                        stimulation_frames_per_epoch::Number=32768)

    round(rounded_freq/(stimulation_sample_rate / stimulation_frames_per_epoch)) *
                                                                stimulation_sample_rate / stimulation_frames_per_epoch
end


