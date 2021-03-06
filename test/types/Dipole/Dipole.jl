facts("Dipoles") do

    dips = Dipole[]

    context("Create") do

        dip1 = Dipole("Talairach", 1, 2, 3, 0, 0, 0, 1, 1, 1)
        dip2 = Dipole("Talairach", 1, 2, 3, 0, 0, 0, 2, 2, 2)

        dips = push!(dips, dip1)
        dips = push!(dips, dip2)
    end

    context("Show") do

        show(dips[1])
        show(dips)
    end
end
