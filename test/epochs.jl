using EEG
using Base.Test
using MAT


#######################################
#
# Test epochs extracted and converted to sweeps
#
#######################################

# Input
fname = joinpath(dirname(@__FILE__), "data", "test.bdf")

s = read_ASSR(fname, verbose=true)
s = extract_epochs(s, verbose=true)
s = create_sweeps(s; epochsPerSweep=4, verbose=true)
julia_result = squeeze(mean(s.processing["sweeps"],2),2)

# MATLAB
filen = matopen(joinpath(dirname(@__FILE__), "data", "sweeps.mat"))
matlab_sweeps = read(filen, "sweep")
close(filen)

@test_approx_eq_eps matlab_sweeps[:,1:6] julia_result 0.0001
