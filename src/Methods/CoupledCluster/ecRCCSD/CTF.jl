"""
    Fermi.CoupledCluster.RCCSD{T}(Alg::CTF)

Compute a RCCSD wave function using the Compiled time factorization algorithm (CTF)
"""
function ecRCCSD{T}(Alg::CTF) where T <: AbstractFloat
    println("Calling CASCI module...")
    # Call CASCI
    cas = Fermi.ConfigurationInteraction.CASCI{T}()

    # Save reference wavefunction and process CAS data
    refwfn = cas.ref
    Casdata = get_cas_data(cas)
    # Delete data that will not be used
    cas = nothing

    # Get MO Integrals
    drop_occ = Fermi.CurrentOptions["drop_occ"]
    drop_vir = Fermi.CurrentOptions["drop_vir"]
    aoint = Fermi.Integrals.ConventionalAOIntegrals() 
    moint = Fermi.Integrals.PhysRestrictedMOIntegrals{T}(refwfn.ndocc, refwfn.nvir, drop_occ, drop_vir, refwfn.C, aoint)
    # Delete AO Integrals
    aoint = nothing

    # Process CAS data to get ecT1 and ecT2 (Cluster Decomposition step)
    frozen = Fermi.CurrentOptions["cas_frozen"]
    active = Fermi.CurrentOptions["cas_active"] ≢ -1 ? Fermi.CurrentOptions["cas_active"] : refwfn.nvir+refwfn.ndocc-frozen
    fcn = Fermi.CurrentOptions["drop_occ"]

    actocc = collect((1+frozen):refwfn.ndocc)
    actvir = collect(1:(active+frozen-refwfn.ndocc))
    @output "Active Occupied Orbitals: {}\n" actocc
    @output "Active Virtual Orbitals:  {}\n" actvir

    T1, T2, ecT1, ecT2 = cas_decomposition(Casdata, refwfn.ndocc, fcn, actocc, actvir, moint.ov, moint.oovv, moint.ovvv, moint.ooov)

    d = [i - a for i = diag(moint.oo), a = diag(moint.vv)]
    D = [i + j - a - b for i = diag(moint.oo), j = diag(moint.oo), a = diag(moint.vv), b = diag(moint.vv)]

    ecRCCSD{T}(refwfn, moint, T1, T2, ecT1, ecT2, d, D, Alg)
end

"""
"""
function ecRCCSD{T}(refwfn::RHF, moint::PhysRestrictedMOIntegrals, newT1::Array{T, 2}, newT2::Array{T,4}, ecT1::Array{T,2}, ecT2::Array{T,4}, d::Array{T,2}, D::Array{T,4}, Alg::CTF) where T <: AbstractFloat

    # Print intro
    Fermi.CoupledCluster.print_header()
    @output "\n    • Computing Externally Corrected CCSD with the ecRCCSD module.\n\n"

    # Process Fock matrix, important for non HF cases
    foo = similar(moint.oo)
    foo .= moint.oo - Diagonal(moint.oo)
    fvv = similar(moint.vv)
    fvv .= moint.vv - Diagonal(moint.vv)
    fov = moint.ov
    
    # Compute Guess Energy
    Ecc = update_energy(newT1, newT2, fov, moint.oovv)
    
    @output "Energy from the CAS Vector:   {:15.10f}\n\n" Ecc+refwfn.energy

    # Start CC iterations
    
    cc_max_iter = Fermi.CurrentOptions["cc_max_iter"]
    cc_e_conv = Fermi.CurrentOptions["cc_e_conv"]
    cc_max_rms = Fermi.CurrentOptions["cc_max_rms"]

    @output "    Starting CC Iterations\n\n"
    @output "Iteration Options:\n"
    @output "   cc_max_iter →  {:3.0d}\n" Int(cc_max_iter)
    @output "   cc_e_conv   →  {:2.0e}\n" cc_e_conv
    @output "   cc_max_rms  →  {:2.0e}\n\n" cc_max_rms
    @output "{:10s}    {: 15s}    {: 12s}    {:12s}    {:10s}\n" "Iteration" "CC Energy" "ΔE" "Max RMS" "Time (s)"

    r1 = 1
    r2 = 1
    dE = 1
    rms = 1
    ite = 1
    T1 = similar(newT1)
    T2 = similar(newT2)

    while abs(dE) > cc_e_conv || rms > cc_max_rms
        if ite > cc_max_iter
            @output "\n⚠️  CC Equations did not converge in {:1.0d} iterations.\n" cc_max_iter
            break
        end
        t = @elapsed begin

            T1 .= newT1
            T2 .= newT2
            update_amp(T1, T2, newT1, newT2, foo, fov, fvv, moint)

            # Apply external correction
            newT1 += ecT1
            newT2 += ecT2

            # Apply resolvent
            newT1 ./= d
            newT2 ./= D

            # Compute residues 
            r1 = sqrt(sum((newT1 - T1).^2))/length(T1)
            r2 = sqrt(sum((newT2 - T2).^2))/length(T2)
        end
        rms = max(r1,r2)
        oldE = Ecc
        Ecc = update_energy(newT1, newT2, fov, moint.oovv)
        dE = Ecc - oldE
        @output "    {:<5.0d}    {:<15.10f}    {:<12.10f}    {:<12.10f}    {:<10.5f}\n" ite Ecc dE rms t
        ite += 1
    end

    # Converged?
    if abs(dE) < cc_e_conv && rms < cc_max_rms
        @output "\n 🍾 Equations Converged!\n"
    end
    @output "\n⇒ Final ecCCSD Energy:     {:15.10f}\n" Ecc+refwfn.energy

end

function get_cas_data(cas::Fermi.ConfigurationInteraction.CASCI)

    # This function process the CAS wave function to return chunks of CI coefficients and determinants
    # corresponding to each excitation level (1, 2, 3 or 4)
    # CI coefficients are intermediate normalized.
    # The reference determinant is taken as the HF one.

    dets = cas.dets
    Ccas = cas.coef

    # REF
    ref = dets[1]
    C0 = Ccas[1]

    # Intermediate Normalization
    abs(C0) > 1e-8 ? nothing : error("Reference coefficient is too small ($(C0)) to performe intermediate normalization")
    Ccas = Ccas ./ C0

    # Split the Cas data into excitation level
    Ccas_ex1or2 = Float64[]
    dets_ex1or2 = Determinant[]

    Ccas_ex3 = Float64[]
    dets_ex3 = Determinant[]

    Ccas_ex4 = Float64[]
    dets_ex4 = Determinant[]

    for i in eachindex(dets)

        exc = excitation_level(ref, dets[i])

        if exc == 1 || exc == 2
            push!(Ccas_ex1or2, Ccas[i])
            push!(dets_ex1or2, dets[i])

        elseif  exc == 3
            push!(Ccas_ex3, Ccas[i])
            push!(dets_ex3, dets[i])

        elseif  exc == 4
            push!(Ccas_ex4, Ccas[i])
            push!(dets_ex4, dets[i])
        end
    end

    return ref, Ccas_ex1or2, dets_ex1or2, Ccas_ex3, dets_ex3, Ccas_ex4, dets_ex4
end

function get_casT1_casT2!(T1::Array{Float64,2}, T2::Array{Float64,4}, Ccas::Array{Float64,1}, dets::Array{Determinant,1}, ref::Determinant, frozen::Int, ndocc::Int)

    for id in eachindex(dets)

        @inbounds D = dets[id]
        αexc = αexcitation_level(ref, D)
        βexc = βexcitation_level(ref, D)

        if αexc == 1

            if βexc == 0

                i, = αexclusive(ref, D) .- frozen     # i is absolute. Take out the frozen orbitals to match the T arrays.
                a, = αexclusive(D, ref) .- ndocc      # a is abolute. Take out the occupied orbitals to get relative (virtual) index

                p = phase(ref, D)

                @inbounds T1[i,a] = Ccas[id]*p

            elseif βexc == 1

                i, = αexclusive(ref, D) .- frozen
                j, = βexclusive(ref, D) .- frozen
                a, = αexclusive(D, ref) .- ndocc
                b, = βexclusive(D, ref) .- ndocc

                p = phase(ref, D)

                @inbounds T2[i,j,a,b] = Ccas[id]*p
            end

        elseif (αexc + βexc) > 2
            # This line relies on the fact the dets are ordered by excitation level
            break
        end
    end

    @tensor T2[i,j,a,b] -= T1[i,a]*T1[j,b] 
end

function get_casT3!(T3::Array{Float64,4}, n::Int, f::Int, Ccas::Array{Float64,1}, dets::Array{Determinant,1}, ref::Determinant, frozen::Int, ndocc::Int, T1::Array{Float64,2}, T2::Array{Float64,4})

    # This function produces a particular slice of the full T3 array T3[:,:,n,:,:,f] for the αβα case
    # Note that n and f are relative indices

    # Clean up array
    fill!(T3, 0.0)

    for id in eachindex(dets)

        @inbounds D = dets[id]
        αexc = αexcitation_level(ref, D)
        βexc = βexcitation_level(ref, D)

        if αexc == 2 && βexc == 1

            # i > k, a > c
            k,i = αexclusive(ref, D) .- frozen
            j,  = βexclusive(ref, D) .- frozen

            if !(n in [k,i])
                continue
            end

            c,a = αexclusive(D, ref) .- ndocc
            b,  = βexclusive(D, ref) .- ndocc

            if !(f in [c,a])
                continue
            end

            # The phase is obtained by appliying annihilation and creation operations onto the referece in the order abckji
            # n and f must be in the positions k and c. a and i are the orb index that don't match n and f.

            n == k ? o1 = i : o1 = k
            f == c ? o3 = a : o3 = c

            p = 1
            _det = Determinant(ref.α, ref.β)

            _p, _det = annihilate(_det, o1+frozen, 'α')
            p = _p*p
            _p, _det = annihilate(_det, j+frozen,  'β')
            p = _p*p
            _p, _det = annihilate(_det, n+frozen,  'α')
            p = _p*p

            _p, _det = create(_det, f+ndocc,  'α')
            p = _p*p
            _p, _det = create(_det, b+ndocc,  'β')
            p = _p*p
            _p, _det = create(_det, o3+ndocc, 'α')
            p = _p*p

            T3[o1,j,o3,b] = p*Ccas[id]

        end
    end

    # Arrays for decomposition
    T1_1n2f = T1[n,f]
    T1_2f = view(T1,:,f)
    T1_1n = view(T1,n,:)
    T2_1n3f = view(T2,n,:,f,:)
    T2_3f = view(T2,:,:,f,:)
    T2_1n = view(T2,n,:,:,:)
    T2_1n4f = view(T2,n,:,:,f)
    T2_2n4f = view(T2,:,n,:,f)

    @tensoropt begin
        # Decomposition of T3
        T3[i,j,a,b] -= T1[i,a]*T1[j,b]*T1_1n2f
        T3[i,j,a,b] += T1_2f[i]*T1[j,b]*T1_1n[a]
        T3[i,j,a,b] -= T1[i,a]*T2_1n3f[j,b]
        T3[i,j,a,b] += T1_1n[a]*T2_3f[i,j,b]
        T3[i,j,a,b] += T1_2f[i]*T2_1n[j,a,b] - T1_1n2f*T2[i,j,a,b]
        T3[i,j,a,b] += T1[j,b]*T2_1n4f[i,a]
        T3[i,j,a,b] -= T1[j,b]*T2_2n4f[i,a]
    end
end

function get_casT4αβ!(T4::Array{Float64,4}, m::Int, n::Int, e::Int, f::Int, Ccas_ex4::Array{Float64,1}, dets_ex4::Array{Determinant,1}, Ccas_ex3::Array{Float64,1}, dets_ex3::Array{Determinant,1}, 
                   ref::Determinant, frozen::Int, ndocc::Int, T1::Array{Float64,2}, T2::Array{Float64,4}, T3_3n6f::Array{Float64,4}, T3_3m6e::Array{Float64,4})
    # Clean up array
    fill!(T4, 0.0)

    for id in eachindex(dets_ex4)

        @inbounds D = dets_ex4[id]
        αexc = αexcitation_level(ref, D)
        βexc = βexcitation_level(ref, D)
        if αexc == 2 && βexc == 2

            # i > k, j > l, a > c, b > d
            k,i = αexclusive(ref, D) .- frozen

            if !(m in [i,k])
                continue
            end

            l,j = βexclusive(ref, D) .- frozen

            if !(n in [l,j])
                continue
            end

            c,a = αexclusive(D,ref) .- ndocc

            if !(e in [c,a])
                continue
            end

            d,b = βexclusive(D, ref) .- ndocc

            if !(f in [d,b])
                continue
            end

            m == i ? o1 = k : o1 = i
            n == j ? o2 = l : o2 = j
            e == a ? o3 = c : o3 = a
            f == b ? o4 = d : o4 = b

            p = 1
            _det = Determinant(ref.α, ref.β)

            _p, _det = annihilate(_det, o1+frozen, 'α')
            p = _p*p
            _p, _det = annihilate(_det, o2+frozen, 'β')
            p = _p*p
            _p, _det = annihilate(_det, m+frozen,  'α')
            p = _p*p
            _p, _det = annihilate(_det, n+frozen,  'β')
            p = _p*p

            _p, _det = create(_det, f+ndocc,  'β')
            p = _p*p
            _p, _det = create(_det, e+ndocc,  'α')
            p = _p*p
            _p, _det = create(_det, o4+ndocc, 'β')
            p = _p*p
            _p, _det = create(_det, o3+ndocc, 'α')
            p = _p*p

            T4[o1,o2,o3,o4] =  p*Ccas_ex4[id]
        end
    end                 

    T1_1m2e = T1[m,e]
    T1_1n2f = T1[n,f]
    pT1 = T1_1m2e*T1_1n2f
    T1_1n = view(T1,n,:)
    T1_2f = view(T1,:,f)
    T1_1m = view(T1,m,:)
    T1_2e = view(T1,:,e)

    T2_1m2n3e4f = T2[m,n,e,f]
    T2_1m3e4f = view(T2,m,:,e,f)
    T2_1n4f = view(T2,n,:,:,f)
    T2_2n4f = view(T2,:,n,:,f)
    T2_1m2n3e = view(T2,m,n,e,:)
    T2_1m3e = view(T2,m,:,e,:)
    T2_2n3e4f = view(T2,:,n,e,f)
    T2_3e4f = view(T2,:,:,e,f)
    T2_2n3e = view(T2,:,n,e,:)
    T2_3e = view(T2,:,:,e,:)
    T2_1m2n4f = view(T2,m,n,:,f)
    T2_1m4e = view(T2,m,:,:,e)
    T2_2m4e = view(T2,:,m,:,e)
    T2_1m4f = view(T2,m,:,:,f)
    T2_4f = view(T2,:,:,:,f)
    T2_1m2n = view(T2,m,n,:,:)
    T2_1m = view(T2,m,:,:,:)
    T2_2n = view(T2,:,n,:,:)

    T3_2m3n5e6f = T3_3n6f[:,m,:,e]
    T3_3n5e6f = T3_3n6f[:,:,:,e]
    T3_2m3n6f = T3_3n6f[:,m,:,:]
    T3_2n3m6e = T3_3m6e[:,n,:,:]
    T3_2n3m5f6e = T3_3m6e[:,n,:,f]
    T3_3m5f6e = T3_3m6e[:,:,:,f]

    @tensoropt begin
        T4[i,j,a,b] -= pT1*T1[j,b]*T1[i,a]
        T4[i,j,a,b] -= T1[j,b]*T1[i,a]*T2_1m2n3e4f
        T4[i,j,a,b] += T1_1n[b]*T1[i,a]*T1_1m2e*T1_2f[j]
        T4[i,j,a,b] += T1_1n[b]*T1[i,a]*T2_1m3e4f[j]
        T4[i,j,a,b] += T1_1m2e*T1[i,a]*T2_1n4f[j,b]
        T4[i,j,a,b] -= T1_1m2e*T1[i,a]*T2_2n4f[j,b]
        T4[i,j,a,b] += T1_2f[j]*T1[i,a]*T2_1m2n3e[b]
        T4[i,j,a,b] -= T1_1n2f*T1[i,a]*T2_1m3e[j,b]
        T4[i,j,a,b] -= T1[i,a]*T3_2m3n5e6f[j,b]
        T4[i,j,a,b] += T1[j,b]*T1_1m[a]*T1_2e[i]*T1_1n2f
        T4[i,j,a,b] += T1[j,b]*T1_1m[a]*T2_2n3e4f[i]
        T4[i,j,a,b] -= T1_1n[b]*T1_1m[a]*T1_2e[i]*T1_2f[j]
        T4[i,j,a,b] -= T1_1n[b]*T1_1m[a]*T2_3e4f[i,j]
        T4[i,j,a,b] -= T1_2e[i]*T1_1m[a]*T2_1n4f[j,b]
        T4[i,j,a,b] += T1_2e[i]*T1_1m[a]*T2_2n4f[j,b]
        T4[i,j,a,b] -= T1_2f[j]*T1_1m[a]*T2_2n3e[i,b]
        T4[i,j,a,b] += T1_1n2f*T1_1m[a]*T2_3e[i,j,b]
        T4[i,j,a,b] += T1_1m[a]*T3_3n5e6f[j,i,b]
        T4[i,j,a,b] += T1_2e[i]*T1[j,b]*T2_1m2n4f[a]
        T4[i,j,a,b] -= T1_1m2e*T1[j,b]*T2_2n4f[i,a]
        T4[i,j,a,b] += T1_1n2f*T1[j,b]*T2_1m4e[i,a]
        T4[i,j,a,b] -= T1_1n2f*T1[j,b]*T2_2m4e[i,a]
        T4[i,j,a,b] -= T1[j,b]*T3_2n3m5f6e[i,a]
        T4[i,j,a,b] -= T1_2e[i]*T1_1n[b]*T2_1m4f[j,a]
        T4[i,j,a,b] += T1_1m2e*T1_1n[b]*T2_4f[i,j,a]
        T4[i,j,a,b] -= T1_2f[j]*T1_1n[b]*T2_1m4e[i,a]
        T4[i,j,a,b] += T1_2f[j]*T1_1n[b]*T2_2m4e[i,a]
        T4[i,j,a,b] += T1_1n[b]*T3_3m5f6e[i,j,a]
        T4[i,j,a,b] -= T1_2f[j]*T1_2e[i]*T2_1m2n[a,b]
        T4[i,j,a,b] += T1_1n2f*T2_1m[j,a,b]*T1_2e[i]
        T4[i,j,a,b] += T1_2e[i]*T3_2m3n6f[j,b,a]
        T4[i,j,a,b] += T1_2f[j]*T1_1m2e*T2_2n[i,a,b] - pT1*T2[i,j,a,b]
        T4[i,j,a,b] -= T1_1m2e*T3_3n6f[j,i,b,a]
        T4[i,j,a,b] += T1_2f[j]*T3_2n3m6e[i,a,b] - T1_1n2f*T3_3m6e[i,j,a,b] - T2_1m2n3e4f*T2[i,j,a,b]
        T4[i,j,a,b] += T2_1m3e4f[j]*T2_2n[i,a,b]
        T4[i,j,a,b] += T2_2n3e4f[i]*T2_1m[j,a,b]
        T4[i,j,a,b] -= T2_3e4f[i,j]*T2_1m2n[a,b]
        T4[i,j,a,b] -= T2_1n4f[j,b]*T2_1m4e[i,a]
        T4[i,j,a,b] += T2_1n4f[j,b]*T2_2m4e[i,a]
        T4[i,j,a,b] += T2_2n4f[j,b]*T2_1m4e[i,a]
        T4[i,j,a,b] -= T2_2n4f[j,b]*T2_2m4e[i,a]
        T4[i,j,a,b] += T2_1m2n3e[b]*T2_4f[i,j,a]
        T4[i,j,a,b] -= T2_1m3e[j,b]*T2_2n4f[i,a]
        T4[i,j,a,b] -= T2_2n3e[i,b]*T2_1m4f[j,a]
        T4[i,j,a,b] += T2_3e[i,j,b]*T2_1m2n4f[a]
    end
end

function get_casT4αα!(T4::Array{Float64,4}, m::Int, n::Int, e::Int, f::Int, Ccas_ex4::Array{Float64,1}, dets_ex4::Array{Determinant,1}, Ccas_ex3::Array{Float64,1}, dets_ex3::Array{Determinant,1}, 
                    ref::Determinant, frozen::Int, ndocc::Int, T1::Array{Float64,2}, T2::Array{Float64,4}, T3_3n6f::Array{Float64,4}, T3_3m6f::Array{Float64,4}, T3_3n6e::Array{Float64,4}, T3_3m6e::Array{Float64,4})
    
    fill!(T4, 0.0)

    if m == n || e == f
        return T4
    end

    for id in eachindex(dets_ex4)

        @inbounds D = dets_ex4[id]
        αexc = αexcitation_level(ref, D)
        βexc = βexcitation_level(ref, D)

        if αexc == 3 && βexc == 1

            # i > k > l, a > c > d
            l,k,i = αexclusive(ref, D) .- frozen

            if !(m in [k,l,i]) || !(n in [k,l,i])
                continue
            end

            j, = βexclusive(ref, D) .- frozen
            d,c,a = αexclusive(D,ref) .- ndocc

            if !(e in [d,c,a]) || !(f in [d,c,a])
                continue
            end

            b, = βexclusive(D, ref) .- ndocc

            o1 = filter(x-> x != m && x != n, [l,k,i])[1]
            o2 = filter(x-> x != e && x != f, [d,c,a])[1]

            p = 1
            _det = Determinant(ref.α, ref.β)

            _p, _det = annihilate(_det, o1+frozen, 'α')
            p = _p*p
            _p, _det = annihilate(_det, j+frozen,  'β')
            p = _p*p
            _p, _det = annihilate(_det, m+frozen,  'α')
            p = _p*p
            _p, _det = annihilate(_det, n+frozen,  'α')
            p = _p*p

            _p, _det = create(_det, f+ndocc,  'α')
            p = _p*p
            _p, _det = create(_det, e+ndocc,  'α')
            p = _p*p
            _p, _det = create(_det, b+ndocc, 'β')
            p = _p*p
            _p, _det = create(_det, o2+ndocc, 'α')
            p = _p*p

            T4[o1,j,o2,b] = p*Ccas_ex4[id]
        end
    end

    # Decomposition
    T1_1m2e = T1[m,e]
    T1_1n2f = T1[n,f]
    T1_1n2e = T1[n,e]
    T1_1m2f = T1[m,f]
    T1_1m = view(T1,m,:)
    T1_2e = view(T1,:,e)
    T1_2f = view(T1,:,f)
    T1_1n = view(T1,n,:)
    pT1_a = T1_1m2e*T1_1n2f
    pT1_b = T1_1n2e*T1_1m2f

    T2_1n2m3e4f = T2[n,m,e,f]
    T2_1m2n3e4f = T2[m,n,e,f]
    T2_1n3f = view(T2,n,:,f,:)
    T2_1m3f = view(T2,m,:,f,:)
    T2_1n3e = view(T2,n,:,e,:)
    T2_1m3e = view(T2,m,:,e,:)
    T2_1n3e4f = view(T2,n,:,e,f)
    T2_2n3e4f = view(T2,:,n,e,f)
    T2_3f = view(T2,:,:,f,:)
    T2_3e = view(T2,:,:,e,:)
    T2_1m3e4f = view(T2,m,:,e,f)
    T2_2m3e4f = view(T2,:,m,e,f)
    T2_1n2m4f = view(T2,n,m,:,f)
    T2_1m2n4f = view(T2,m,n,:,f)
    T2_1n4f = view(T2,n,:,:,f)
    T2_2n4f = view(T2,:,n,:,f)
    T2_1m4f = view(T2,m,:,:,f)
    T2_2m4f = view(T2,:,m,:,f)
    T2_1n2m4e = view(T2,n,m,:,e)
    T2_1m2n4e = view(T2,m,n,:,e)
    T2_1n4e = view(T2,n,:,:,e)
    T2_2n4e = view(T2,:,n,:,e)
    T2_1m4e = view(T2,m,:,:,e)
    T2_2m4e = view(T2,:,m,:,e)
    T2_1n = view(T2,n,:,:,:)
    T2_1m = view(T2,m,:,:,:)

    T3_1m3n4e6f = view(T3_3n6f,m,:,e,:)
    T3_3n4e6f = view(T3_3n6f,:,:,e,:)
    T3_1m3n5e6f = view(T3_3n6f,m,:,:,e)
    T3_2m3n5e6f = view(T3_3n6f,:,m,:,e)
    T3_1m3n6f = view(T3_3n6f,m,:,:,:)

    T3_3m4e6f = view(T3_3m6f,:,:,e,:)
    T3_2n3m5e6f = view(T3_3m6f,:,n,:,e)

    T3_1m3n6e = view(T3_3n6e,m,:,:,:)

    @tensoropt begin
        T4[i,j,a,b] -= T1[j,b]*T1[i,a]*pT1_a
        T4[i,j,a,b] += T1[j,b]*T1[i,a]*pT1_b
        T4[i,j,a,b] += T1[j,b]*T1[i,a]*T2_1n2m3e4f
        T4[i,j,a,b] -= T1[j,b]*T1[i,a]*T2_1m2n3e4f
        T4[i,j,a,b] -= T1_1m2e*T1[i,a]*T2_1n3f[j,b]
        T4[i,j,a,b] += T1_1n2e*T1[i,a]*T2_1m3f[j,b]
        T4[i,j,a,b] += T1_1m2f*T1[i,a]*T2_1n3e[j,b]
        T4[i,j,a,b] -= T1_1n2f*T1[i,a]*T2_1m3e[j,b]
        T4[i,j,a,b] -= T1[i,a]*T3_1m3n4e6f[j,b]
        T4[i,j,a,b] += T1[j,b]*T1_1m[a]*T1_2e[i]*T1_1n2f
        T4[i,j,a,b] -= T1[j,b]*T1_1m[a]*T1_1n2e*T1_2f[i]
        T4[i,j,a,b] -= T1[j,b]*T1_1m[a]*T2_1n3e4f[i]
        T4[i,j,a,b] += T1[j,b]*T1_1m[a]*T2_2n3e4f[i]
        T4[i,j,a,b] += T1_2e[i]*T1_1m[a]*T2_1n3f[j,b]
        T4[i,j,a,b] -= T1_1n2e*T1_1m[a]*T2_3f[i,j,b]
        T4[i,j,a,b] -= T1_2f[i]*T1_1m[a]*T2_1n3e[j,b]
        T4[i,j,a,b] += T1_1n2f*T1_1m[a]*T2_3e[i,j,b]
        T4[i,j,a,b] += T1_1m[a]*T3_3n4e6f[i,j,b]
        T4[i,j,a,b] -= T1[j,b]*T1_1n[a]*T1_2e[i]*T1_1m2f
        T4[i,j,a,b] += T1[j,b]*T1_1n[a]*T1_1m2e*T1_2f[i]
        T4[i,j,a,b] += T1[j,b]*T1_1n[a]*T2_1m3e4f[i]
        T4[i,j,a,b] -= T1[j,b]*T1_1n[a]*T2_2m3e4f[i]
        T4[i,j,a,b] -= T1_2e[i]*T1_1n[a]*T2_1m3f[j,b]
        T4[i,j,a,b] += T1_1m2e*T1_1n[a]*T2_3f[i,j,b]
        T4[i,j,a,b] += T1_2f[i]*T1_1n[a]*T2_1m3e[j,b]
        T4[i,j,a,b] -= T1_1m2f*T1_1n[a]*T2_3e[i,j,b]
        T4[i,j,a,b] -= T1_1n[a]*T3_3m4e6f[i,j,b]   
        T4[i,j,a,b] -= T1_2e[i]*T1[j,b]*T2_1n2m4f[a]
        T4[i,j,a,b] += T1_2e[i]*T1[j,b]*T2_1m2n4f[a]
        T4[i,j,a,b] += T1_1m2e*T1[j,b]*T2_1n4f[i,a]
        T4[i,j,a,b] -= T1_1m2e*T1[j,b]*T2_2n4f[i,a]
        T4[i,j,a,b] -= T1_1n2e*T1[j,b]*T2_1m4f[i,a]
        T4[i,j,a,b] += T1_1n2e*T1[j,b]*T2_2m4f[i,a]
        T4[i,j,a,b] += T1_2f[i]*T1[j,b]*T2_1n2m4e[a]
        T4[i,j,a,b] -= T1_2f[i]*T1[j,b]*T2_1m2n4e[a]
        T4[i,j,a,b] -= T1_1m2f*T1[j,b]*T2_1n4e[i,a]
        T4[i,j,a,b] += T1_1m2f*T1[j,b]*T2_2n4e[i,a]
        T4[i,j,a,b] += T1_1n2f*T1[j,b]*T2_1m4e[i,a]
        T4[i,j,a,b] -= T1_1n2f*T1[j,b]*T2_2m4e[i,a]
        T4[i,j,a,b] += T1[j,b]*T3_1m3n5e6f[i,a]
        T4[i,j,a,b] -= T1[j,b]*T3_2m3n5e6f[i,a]
        T4[i,j,a,b] += T1[j,b]*T3_2n3m5e6f[i,a]  
        T4[i,j,a,b] -= T1_1m2f*T1_2e[i]*T2_1n[j,a,b]
        T4[i,j,a,b] += T1_1n2f*T1_2e[i]*T2_1m[j,a,b]
        T4[i,j,a,b] += T1_2e[i]*T3_1m3n6f[j,a,b]
        T4[i,j,a,b] += T1_2f[i]*T1_1m2e*T2_1n[j,a,b]
        T4[i,j,a,b] -= pT1_a*T2[i,j,a,b]
        T4[i,j,a,b] -= T1_1m2e*T3_3n6f[i,j,a,b]
        T4[i,j,a,b] -= T1_2f[i]*T1_1n2e*T2_1m[j,a,b]
        T4[i,j,a,b] += pT1_b*T2[i,j,a,b]
        T4[i,j,a,b] += T1_1n2e*T3_3m6f[i,j,a,b]  
        T4[i,j,a,b] -= T1_2f[i]*T3_1m3n6e[j,a,b]
        T4[i,j,a,b] += T1_1m2f*T3_3n6e[i,j,a,b]
        T4[i,j,a,b] -= T1_1n2f*T3_3m6e[i,j,a,b]
        T4[i,j,a,b] += T2_1n2m3e4f*T2[i,j,a,b]
        T4[i,j,a,b] -= T2_1m2n3e4f*T2[i,j,a,b]
        T4[i,j,a,b] -= T2_1n3e4f[i]*T2_1m[j,a,b]
        T4[i,j,a,b] += T2_2n3e4f[i]*T2_1m[j,a,b]
        T4[i,j,a,b] += T2_1m3e4f[i]*T2_1n[j,a,b]
        T4[i,j,a,b] -= T2_2m3e4f[i]*T2_1n[j,a,b]
        T4[i,j,a,b] += T2_1n3f[j,b]*T2_1m4e[i,a]
        T4[i,j,a,b] -= T2_1n3f[j,b]*T2_2m4e[i,a]
        T4[i,j,a,b] -= T2_1m3f[j,b]*T2_1n4e[i,a]
        T4[i,j,a,b] += T2_1m3f[j,b]*T2_2n4e[i,a]
        T4[i,j,a,b] += T2_3f[i,j,b]*T2_1n2m4e[a]
        T4[i,j,a,b] -= T2_3f[i,j,b]*T2_1m2n4e[a]
        T4[i,j,a,b] -= T2_1n3e[j,b]*T2_1m4f[i,a]
        T4[i,j,a,b] += T2_1n3e[j,b]*T2_2m4f[i,a]
        T4[i,j,a,b] += T2_1m3e[j,b]*T2_1n4f[i,a]
        T4[i,j,a,b] -= T2_1m3e[j,b]*T2_2n4f[i,a]
        T4[i,j,a,b] -= T2_3e[i,j,b]*T2_1n2m4f[a]
        T4[i,j,a,b] += T2_3e[i,j,b]*T2_1m2n4f[a]
    end
end

function get_ec_from_T3!(n::Int, f::Int, ecT1::Array{Float64,2}, ecT2::Array{Float64,4}, T1::Array{Float64,2}, T3::Array{Float64,4}, fov::Array{Float64, 2}, Voovv::Array{Float64, 4}, Vovvv::Array{Float64, 4}, Vooov::Array{Float64, 4})

    # Arrays for ecT1 and ecT2
    Voovv_1n4f = view(Voovv, n, :, :, f)
    Voovv_2n4f = view(Voovv, :, n, :, f)
    Voovv_1n3f = view(Voovv, n, :, f, :)
    Vovvv_1n4f = view(Vovvv, n, :, :, f)
    Vovvv_1n3f = view(Vovvv, n, :, f, :)
    Vooov_1n4f = view(Vooov, n, :, :, f)
    Vooov_2n4f = view(Vooov, :, n, :, f)
    fov_1n2f = fov[n,f]
    
    @tensoropt begin
    
        # Compute ecT1
        ecT1[i,a] += 0.25*T3[m,i,e,a]*Voovv_2n4f[m,e]
        ecT1[i,a] += 1.5*T3[i,m,a,e]*Voovv_2n4f[m,e]
        ecT1[i,a] += -0.25*T3[m,i,a,e]*Voovv_2n4f[m,e]
        ecT1[i,a] += -0.5*T3[i,m,a,e]*Voovv_1n4f[m,e]
        ecT1[i,a] += -0.25*T3[m,i,e,a]*Voovv_1n4f[m,e]
        ecT1[i,a] += 0.25*T3[m,i,a,e]*Voovv_1n4f[m,e]
    
        # Compute ecT2
        ecT2[i,j,a,b] += fov_1n2f*T3[j,i,b,a]
        ecT2[i,j,a,b] += fov_1n2f*T3[i,j,a,b]
        ecT2[i,j,a,b] += -0.5*T3[i,j,e,b]*Vovvv_1n4f[a,e]
        ecT2[i,j,a,b] += 0.5*T3[i,j,e,b]*Vovvv_1n3f[a,e]
        ecT2[i,j,a,b] += T3[j,i,b,e]*Vovvv_1n3f[a,e]
        ecT2[i,j,a,b] += 0.5*T3[m,j,a,b]*Vooov_1n4f[m,i]
        ecT2[i,j,a,b] += -0.5*T3[m,j,a,b]*Vooov_2n4f[m,i]
        ecT2[i,j,a,b] -= T3[j,m,b,a]*Vooov_2n4f[m,i]
        ecT2[i,j,a,b] += 0.5*T3[m,i,b,a]*Vooov_1n4f[m,j]
        ecT2[i,j,a,b] -= T3[i,m,a,b]*Vooov_2n4f[m,j]
        ecT2[i,j,a,b] += -0.5*T3[m,i,b,a]*Vooov_2n4f[m,j]
        ecT2[i,j,a,b] += -0.5*T3[j,i,e,a]*Vovvv_1n4f[b,e]
        ecT2[i,j,a,b] += T3[i,j,a,e]*Vovvv_1n3f[b,e]
        ecT2[i,j,a,b] += 0.5*T3[j,i,e,a]*Vovvv_1n3f[b,e]
        ecT2[i,j,a,b] -= T1[m,b]*T3[i,j,a,e]*Voovv_2n4f[m,e]
        ecT2[i,j,a,b] += -0.5*T1[m,b]*T3[j,i,e,a]*Voovv_2n4f[m,e]
        ecT2[i,j,a,b] += 0.5*T1[m,b]*T3[j,i,e,a]*Voovv_1n4f[m,e]
        ecT2[i,j,a,b] += 0.5*T1[m,a]*T3[i,j,e,b]*Voovv_1n4f[m,e]
        ecT2[i,j,a,b] += -0.5*T1[m,a]*T3[i,j,e,b]*Voovv_2n4f[m,e]
        ecT2[i,j,a,b] -= T1[m,a]*T3[j,i,b,e]*Voovv_1n3f[m,e]
        ecT2[i,j,a,b] -= T1[j,e]*T3[i,m,a,b]*Voovv_2n4f[m,e]
        ecT2[i,j,a,b] += 0.5*T1[j,e]*T3[m,i,b,a]*Voovv_1n4f[m,e]
        ecT2[i,j,a,b] += -0.5*T1[j,e]*T3[m,i,b,a]*Voovv_2n4f[m,e]
        ecT2[i,j,a,b] += 0.5*T1[i,e]*T3[m,j,a,b]*Voovv_1n4f[m,e]
        ecT2[i,j,a,b] += -0.5*T1[i,e]*T3[m,j,a,b]*Voovv_2n4f[m,e]
        ecT2[i,j,a,b] -= T1[i,e]*T3[j,m,b,a]*Voovv_2n4f[m,e]
        ecT2[i,j,a,b] -= T1[m,e]*T3[i,j,a,b]*Voovv_1n4f[m,e]
        ecT2[i,j,a,b] += 2.0*T1[m,e]*T3[i,j,a,b]*Voovv_2n4f[m,e]
        ecT2[i,j,a,b] -= T1[m,e]*T3[j,i,b,a]*Voovv_1n4f[m,e]
        ecT2[i,j,a,b] += 2.0*T1[m,e]*T3[j,i,b,a]*Voovv_2n4f[m,e]
    end

end

function cas_decomposition(Cas_data::Tuple, ndocc::Int, frozen::Int, actocc::Array{Int64,1}, actvir::Array{Int64,1},
                           fov::Array{Float64,2}, Voovv::Array{Float64,4}, Vovvv::Array{Float64,4}, Vooov::Array{Float64,4})

    ref, Ccas_ex1or2, dets_ex1or2, Ccas_ex3, dets_ex3, Ccas_ex4, dets_ex4 = Cas_data

    # Get T1 and T2
    T1 = zeros(size(fov))
    T2 = zeros(size(Voovv))
    get_casT1_casT2!(T1, T2, Ccas_ex1or2, dets_ex1or2, ref, frozen, ndocc)

    # Initialize arrays
    ecT1 = zeros(size(fov))
    ecT2 = zeros(size(Voovv))

    # Allocate arrays
    T3_3n6f = similar(T2)
    T3_3m6f = similar(T2)
    T3_3n6e = similar(T2)
    T3_3m6e = similar(T2)
    T4αβ = similar(T2)
    T4αα = similar(T2)

    # Compute ecT1
    for n in actocc 
        for f in actvir

            get_casT3!(T3_3n6f, n, f, Ccas_ex3, dets_ex3, ref, frozen, ndocc, T1, T2)
            get_ec_from_T3!(n, f, ecT1, ecT2, T1, T3_3n6f, fov, Voovv, Vovvv, Vooov)

            for m in actocc 

                get_casT3!(T3_3m6f, m, f, Ccas_ex3, dets_ex3, ref, frozen, ndocc, T1, T2)

                for e in actvir

                    get_casT3!(T3_3m6e, m, e, Ccas_ex3, dets_ex3, ref, frozen, ndocc, T1, T2)
                    get_casT3!(T3_3n6e, n, e, Ccas_ex3, dets_ex3, ref, frozen, ndocc, T1, T2)

                    get_casT4αβ!(T4αβ, m,n,e,f, Ccas_ex4, dets_ex4, Ccas_ex3, dets_ex3, ref, frozen, ndocc, T1, T2, T3_3n6f, T3_3m6e)
                    get_casT4αα!(T4αα, m,n,e,f, Ccas_ex4, dets_ex4, Ccas_ex3, dets_ex3, ref, frozen, ndocc, T1, T2, T3_3n6f, T3_3m6f, T3_3n6e, T3_3m6e)

                    ecT2 += T4αβ.*Voovv[m,n,e,f]
                    ecT2 += 0.25.*(T4αα + permutedims(T4αα, [2,1,4,3])).*(Voovv[m,n,e,f] - Voovv[n,m,e,f])
                end
            end
        end
    end

    return T1, T2, ecT1, ecT2
end
