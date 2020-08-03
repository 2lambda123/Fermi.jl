using TensorOperations
"""
    Fermi.HartreeFock.RHF(molecule::Molecule, aoint::ConventionalAOIntegrals, Alg::ConventionalRHF)

Conventional algorithm for to compute RHF wave function given Molecule, Integrals objects.
"""
function RHF(molecule::Molecule, aoint::DFAOIntegrals, Alg::DFRHF)

    @output "Using GWH Guess\n"
    S = Hermitian(aoint.S)
    A = S^(-1/2)
    H = Hermitian(aoint.T + aoint.V)
    ndocc = molecule.Nα#size(S,1)
    nvir = size(S,1) - ndocc
    F = Array{Float64,2}(undef, ndocc+nvir, ndocc+nvir)
    for i = 1:ndocc+nvir
        F[i,i] = H[i,i]
        for j = 1:ndocc+nvir
            F[i,j] = 0.875*S[i,j]*(H[i,i] + H[j,j])
            F[j,i] = F[i,j]
        end
    end
    Ft = A*F*transpose(A)

    # Get orbital energies and transformed coefficients
    eps,Ct = eigen(Hermitian(Ft))

    # Reverse transformation to get MO coefficients
    C = A*Ct

    RHF(molecule, aoint, C, Alg)
end

"""
    Fermi.HartreeFock.RHF(wfn::RHF, Alg::ConventionalRHF)

Conventional algorithm for to compute RHF wave function. Inital guess for orbitals is built from given RHF wfn.
"""
function RHF(wfn::RHF, Alg::DFRHF)

    aoint = ConventionalAOIntegrals(Fermi.Geometry.Molecule())
    RHF(wfn, aoint, Alg)
end

"""
    Fermi.HartreeFock.RHF(wfn::RHF, aoint::ConventionalAOIntegrals, Alg::ConventionalRHF)

Conventional algorithm for to compute RHF wave function. Inital guess for orbitals is built from given RHF wfn. Integrals
are taken from the aoint input.
"""
function RHF(wfn::RHF, aoint::DFAOIntegrals, Alg::DFRHF)

    # Projection of A→B done using equations described in Werner 2004 
    # https://doi.org/10.1080/0026897042000274801
    @output "Using {} wave function as initial guess\n" wfn.basis
    Ca = wfn.C
    Sbb = aoint.S
    Sab = Lints.projector(wfn.LintsBasis, aoint.LintsBasis)
    T = transpose(Ca)*Sab*(Sbb^-1)*transpose(Sab)*Ca
    Cb = (Sbb^-1)*transpose(Sab)*Ca*T^(-1/2)
    Cb = real.(Cb)
    RHF(Fermi.Geometry.Molecule(), aoint, Cb, Alg)
end

"""
    Fermi.HartreeFock.RHF(molecule::Molecule, aoint::ConventionalAOIntegrals, Cguess::Array{Float64,2}, Alg::ConventionalRHF)

Basic function for conventional RHF using conventional integrals.
"""
function RHF(molecule::Molecule, aoint::DFAOIntegrals, C::Array{Float64,2}, Alg::DFRHF)
    # Print header
    do_diis = Fermi.CurrentOptions["diis"]
    Fermi.HartreeFock.print_header()

    do_diis ? DM = Fermi.DIIS.DIISManager{Float64,Float64}(size=8) : nothing 
    # Look up iteration options
    maxit = Fermi.CurrentOptions["scf_max_iter"]
    Etol  = 10.0^(-Fermi.CurrentOptions["e_conv"])
    Dtol  = Fermi.CurrentOptions["scf_max_rms"]

    ndocc = try
        Int((molecule.Nα + molecule.Nβ)/2)
    catch InexactError
        throw(Fermi.InvalidFermiOption("Invalid number of electrons $(molecule.Nα + molecule.Nβ) for RHF method."))
    end

    nvir = size(aoint.S)[1] - ndocc

    @output " Number of Doubly Occupied Orbitals:   {:5.0d}\n" ndocc
    @output " Number of Virtual Spatial Orbitals:   {:5.0d}\n" nvir

    # Form the orthogonalizer 
    sS = Hermitian(aoint.S)
    A = sS^(-1/2)

    # Form the density matrix
    Co = C[:, 1:ndocc]
    D = Fermi.contract(Co,Co,"um","vm")
    
    F = Array{Float64,2}(undef, ndocc+nvir, ndocc+nvir)
    eps = Array{Float64, 1}(undef, ndocc+nvir)
    ite = 1
    converged = false

    @output "\n Iter.   {:>15} {:>10} {:>10} {:>8} {:>8}\n" "E[RHF]" "ΔE" "√|ΔD|²" "t" "DIIS"
    @output repeat("~",80)*"\n"


    # Produce new Density Matrix
    Co = C[:,1:ndocc]
    D = Fermi.contract(Co,Co,"um","vm")
    diis_start = 3
    E = 0.0
    t = @elapsed while ite ≤ maxit
        t_iter = @elapsed begin

            # Build the Fock Matrix
            F_old = deepcopy(F)
            build_fock!(F, aoint.T+aoint.V, D, aoint.B,Alg)
            Eelec = RHFEnergy(D, aoint.T+aoint.V, F)
            #ite == 1 ? display(F) : nothing


            do_diis ? err = transpose(A)*(F*D*aoint.S - aoint.S*D*F)*A : nothing
            do_diis ? push!(DM, F, err) : nothing
            do_diis && ite > diis_start ? F = Fermi.DIIS.extrapolate(DM) : nothing

            # Produce Ft
            Ft = A*F*transpose(A)

            # Get orbital energies and transformed coefficients
            eps,Ct = eigen(Hermitian(Ft))

            # Reverse transformation to get MO coefficients
            C = A*Ct

            # Produce new Density Matrix
            Co = C[:,1:ndocc]
            Dnew = Fermi.contract(Co,Co,"um","vm")
            #@tensor Dnew[u,v] := Co[u,m]*Co[v,m]

            # Compute Energy
            Enew = Eelec + molecule.Vnuc

            # Compute the Density RMS
            ΔD = Dnew - D
            Drms = sqrt(sum(ΔD.^2))

            # Compute Energy Change
            ΔE = Enew - E
            D .= Dnew
            E = Enew
        end
        @output "    {:<3} {:>15.10f} {:>11.3e} {:>11.3e} {:>8.2f} {:>8}\n" ite E ΔE Drms t_iter (do_diis && ite > diis_start)
        ite += 1

        if (abs(ΔE) < Etol) & (Drms < Dtol) & (ite > 5)
            converged = true
            break
        end
    end

    @output repeat("~",80)*"\n"
    @output "    RHF done in {:>5.2f}s\n" t
    @output "    @E[RHF] = {:>20.16f}\n" E

    @output "\n   • Orbitals Summary\n"
    @output "\n {:>10}   {:>15}   {:>10}\n" "Orbital" "Energy" "Occupancy"
    for i in eachindex(eps)
            @output " {:>10}   {:> 15.10f}   {:>6}\n" i eps[i] (i ≤ ndocc ? "↿⇂" : "")
    end
    
    if !converged
        @output "\n !! SCF Equations did not converge in {:>5} iterations !!\n" maxit
    end
    return RHF(aoint.bname, aoint.basis, molecule, E, ndocc, nvir, C, eps)
end

function RHFEnergy(D::Array{Float64,2}, H::Array{Float64,2},F::Array{Float64,2})
    return sum(D .* (H .+ F))
end

function build_fock!(F::Array{Float64,2}, H::Array{Float64,2}, D::Array{Float64,2}, ERI::Array{Float64,3}, Alg::DFRHF)
    F .= H
    sz = size(F,1)
    dfsz = size(ERI,1)
    Fp = zeros(dfsz)
    Fermi.contract!(Fp,D,ERI,1.0,1.0,2.0,"Q","rs","Qrs")
    Fermi.contract!(F,Fp,ERI,1.0,1.0,1.0,"mn","Q","Qmn")
    Fp = zeros(dfsz,sz,sz)
    Fermi.contract!(Fp,D,ERI,0.0,1.0,-1.0,"Qrn","rs","Qns")
    Fermi.contract!(F,ERI,Fp,1.0,1.0,1.0,"mn","Qmr","Qrn")
end
