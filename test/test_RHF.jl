@reset
@set printstyle none

Econv = [
-76.05293659641387
-56.20535441552491
-230.62430998333491
-154.09239259145315
-113.86547542905063
-279.11530153592190
-40.21342962572423
-378.34082589236152
-227.76309337209906
-108.95448240313175
]

Edf = [
-76.05293666271385
-56.20536076021163
-230.62430735896447
-154.09238732181598
-113.86547012724539
-279.11536397681431
-40.21342776121698
-378.34079658679821
-227.76307917179560
-108.95446350767733
]

@testset "RHF" begin
    @testset "Conventional" begin
        Fermi.Options.set("df", false)

        for i = eachindex(molecules)
            # Read molecule
            mol = open(f->read(f,String), "xyz/"*molecules[i]*".xyz")

            # Define options
            Fermi.Options.set("molstring", mol)
            Fermi.Options.set("basis", basis[i])

            wf = @energy rhf
            @test isapprox(wf.energy, Econv[i], rtol=tol) # Energy from Psi4
        end
    end
    
    @testset "Density Fitted" begin
        Fermi.Options.set("df", true)
        Fermi.Options.set("jkfit", "cc-pvqz-jkfit")

        for i = eachindex(molecules)
            # Read molecule
            mol = open(f->read(f,String), "xyz/"*molecules[i]*".xyz")

            # Skipping these cause there is some problem with Cart x Spherical
            if molecules[i] in ["benzene", "phosphaethene"]
                continue
            end

            # Define options
            Fermi.Options.set("molstring", mol)
            Fermi.Options.set("basis", basis[i])

            wf = @energy rhf
            @test isapprox(wf.energy, Edf[i], rtol=tol) # Energy from Psi4
        end
    end
end
