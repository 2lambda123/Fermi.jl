module Libcint

export cint1e_kin_sph!, cint1e_nuc_sph!, cint1e_ovlp_sph!, cint2c2e_sph!, cint2e_sph!, cint3c2e_sph!

const LIBCINT = joinpath(@__DIR__, "../../deps/libcint.so")

function CINTcgtos_spheric(bas_id, bas)
    @ccall LIBCINT.CINTcgtos_spheric(bas_id::Cint, bas::Ptr{Cint})::Cint
end

function cint1e_ovlp_sph!(buf, shls, atm, natm, bas, nbas, env)
    @ccall LIBCINT.cint1e_ovlp_sph(
                                    buf  :: Ptr{Cdouble},
                                    shls :: Ptr{Cint},
                                    atm  :: Ptr{Cint},
                                    natm :: Cint,
                                    bas  :: Ptr{Cint},
                                    nbas :: Cint,
                                    env  :: Ptr{Cdouble}
                                   )::Cvoid
end

function cint1e_kin_sph!(buf, shls, atm, natm, bas, nbas, env)
    @ccall LIBCINT.cint1e_kin_sph(
                                    buf  :: Ptr{Cdouble},
                                    shls :: Ptr{Cint},
                                    atm  :: Ptr{Cint},
                                    natm :: Cint,
                                    bas  :: Ptr{Cint},
                                    nbas :: Cint,
                                    env  :: Ptr{Cdouble}
                                   )::Cvoid
end

function cint1e_nuc_sph!(buf, shls, atm, natm, bas, nbas, env)
    @ccall LIBCINT.cint1e_nuc_sph(
                                    buf  :: Ptr{Cdouble},
                                    shls :: Ptr{Cint},
                                    atm  :: Ptr{Cint},
                                    natm :: Cint,
                                    bas  :: Ptr{Cint},
                                    nbas :: Cint,
                                    env  :: Ptr{Cdouble}
                                   )::Cvoid
end

function cint2e_sph!(buf, shls, atm, natm, bas, nbas, env)
    opt = Ptr{UInt8}(C_NULL)
    @ccall LIBCINT.cint2e_sph(
                                    buf  :: Ptr{Cdouble},
                                    shls :: Ptr{Cint},
                                    atm  :: Ptr{Cint},
                                    natm :: Cint,
                                    bas  :: Ptr{Cint},
                                    nbas :: Cint,
                                    env  :: Ptr{Cdouble},
                                    opt :: Ptr{UInt8},
                                   )::Cvoid
end

function cint2c2e_sph!(buf, shls, atm, natm, bas, nbas, env)
    opt = Ptr{UInt8}(C_NULL)
    @ccall LIBCINT.cint2c2e_sph(
                                    buf  :: Ptr{Cdouble},
                                    shls :: Ptr{Cint},
                                    atm  :: Ptr{Cint},
                                    natm :: Cint,
                                    bas  :: Ptr{Cint},
                                    nbas :: Cint,
                                    env  :: Ptr{Cdouble},
                                    opt :: Ptr{UInt8},
                                   )::Cvoid
end

function cint3c2e_sph!(buf, shls, atm, natm, bas, nbas, env)
    opt = Ptr{UInt8}(C_NULL)
    @ccall LIBCINT.cint3c2e_sph(
                                    buf  :: Ptr{Cdouble},
                                    shls :: Ptr{Cint},
                                    atm  :: Ptr{Cint},
                                    natm :: Cint,
                                    bas  :: Ptr{Cint},
                                    nbas :: Cint,
                                    env  :: Ptr{Cdouble},
                                    opt :: Ptr{UInt8},
                                   )::Cvoid
end


end #module