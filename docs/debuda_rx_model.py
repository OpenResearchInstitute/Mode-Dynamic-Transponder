import numpy as np
fs,R=625000.0,54200.0; fdev,fline,sps=R/4,R/2,fs/R

def gen_msk(bits,theta_c=0.0,snr_db=None,seed=0):
    nsamp=int(len(bits)*sps)+1; n=np.arange(nsamp)
    sym=np.minimum((n/sps).astype(int),len(bits)-1)
    psi=np.cumsum(2*np.pi*(fdev*bits[sym])/fs); z=np.exp(1j*(theta_c+psi))
    if snr_db is not None:
        rng=np.random.default_rng(seed); npow=1/(10**(snr_db/10))
        z=z+np.sqrt(npow/2)*(rng.standard_normal(nsamp)+1j*rng.standard_normal(nsamp))
    return z,nsamp,sym

def lpf(x,a):
    y=np.zeros_like(x);acc=0j
    for n in range(len(x)):acc+=a*(x[n]-acc);y[n]=acc
    return y

def debuda_rx(z,N,n_pre_sym):
    n=np.arange(N)
    # ---- SYNC: square, isolate the two R/2 lines ----
    w=z*z
    lp_hi=lpf(w*np.exp(-1j*2*np.pi*fline*n/fs),0.004)
    lp_lo=lpf(w*np.exp(+1j*2*np.pi*fline*n/fs),0.004)
    # ---- CARRIER: 2*theta_c lives in each line; combine for noise, /2 for theta_c (pi ambig) ----
    car2 = lp_hi*np.conj(lp_hi)*0 + (lp_hi/np.abs(lp_hi) + lp_lo/np.abs(lp_lo))  # avg unit phasors -> e^{j2θc}*const
    theta_hat = 0.5*np.angle(car2)                      # /2  -> 180deg ambiguity
    # ---- CLOCK: timing phase from the line difference; instantaneous beat gives symbol edges ----
    beat = lp_hi*np.conj(lp_lo)                          # ~const phasor carrying (a_hi - a_lo)
    timing_phase = np.angle(beat)                        # radians, ~const
    # symbol centers: phase 2*pi*R*t/fs + timing must hit 2*pi*(k+0.5)
    # k_center sample = ((k+0.5)*2pi - timing)/(2pi R/fs)
    return w,lp_hi,lp_lo,theta_hat,timing_phase

def detect(z,N,theta_hat,timing_phase,nsym):
    n=np.arange(N)
    zc = z*np.exp(-1j*theta_hat)                         # derotate by recovered carrier
    tp = np.mean(timing_phase[int(300*sps):])           # steady timing
    # symbol-center sample index for symbol k
    centers = ((np.arange(nsym)+0.5)*2*np.pi - tp)/(2*np.pi*R/fs)
    bits=np.zeros(nsym)
    bits_nc=np.zeros(nsym)
    half=sps/2
    tone=np.exp(1j*2*np.pi*fdev*np.arange(-int(half),int(half)+1)/fs)
    for k in range(nsym):
        c=int(round(centers[k]))
        if c-int(half)<0 or c+int(half)+1>N: 
            bits[k]=bits_nc[k]=np.nan; continue
        seg=zc[c-int(half):c+int(half)+1]
        cp=np.sum(seg*np.conj(tone)); cm=np.sum(seg*tone)
        bits[k]    = 1 if np.real(cp)>np.real(cm) else -1   # COHERENT (real part, uses carrier)
        bits_nc[k] = 1 if np.abs(cp)>np.abs(cm) else -1     # non-coherent (magnitude)
    return bits,bits_nc

# ---- build signal: 256-sym preamble + random payload ----
nsym=4000; npre=256
rng=np.random.default_rng(11)
data=rng.integers(0,2,nsym-npre)*2-1
bits=np.concatenate([np.tile([1,1,-1,-1],npre//4),data])

print("=== END-TO-END BER (coherent vs non-coherent), de Buda complex RX ===")
for snr in [30,20,15,12,10,8,6]:
    z,N,truesym=gen_msk(bits,theta_c=0.9,snr_db=snr,seed=5)
    w,hi,lo,th,tp=debuda_rx(z,N,npre)
    bhat,bhat_nc=detect(z,N,th,tp,nsym)
    # align on preamble to resolve 180deg ambiguity, score payload only
    valid=~np.isnan(bhat)
    sl=slice(npre+5,nsym-5)
    def ber(est):
        e=est[sl]; t=bits[sl]; m=~np.isnan(e)
        err=np.mean(e[m]!=t[m]); err2=np.mean((-e[m])!=t[m])
        return min(err,err2)   # resolve global sign ambiguity
    print(f"  SNR {snr:2d} dB : coherent BER = {ber(bhat):.4f}    non-coh BER = {ber(bhat_nc):.4f}")

# ---------------- summary figure ----------------
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
z,N,_=gen_msk(bits,theta_c=0.9,snr_db=20,seed=5)
w,hi,lo,th,tp=debuda_rx(z,N,npre)
n=np.arange(N); t_ms=n/fs*1e3
fig,ax=plt.subplots(2,2,figsize=(12,7))
# (1) spectra
def sp(x):
    X=np.fft.fftshift(np.abs(np.fft.fft(x*np.hanning(len(x)))));f=np.fft.fftshift(np.fft.fftfreq(len(x),1/fs))
    return f/1e3,20*np.log10(X/X.max()+1e-12)
f,S=sp(z); ax[0,0].plot(f,S,lw=.6,label='z (raw)')
f,S=sp(w); ax[0,0].plot(f,S,lw=.6,label='z² (squared)')
for fx in (-fline/1e3,fline/1e3): ax[0,0].axvline(fx,color='r',ls='--',lw=.8)
ax[0,0].set_xlim(-50,50);ax[0,0].set_ylim(-80,2);ax[0,0].legend(fontsize=8);ax[0,0].set_title('Squaring makes data-free lines at ±R/2');ax[0,0].set_xlabel('kHz')
# (2) lock acquisition: |lp| settling
ax[0,1].plot(t_ms,np.abs(hi),lw=.7,label='|line +R/2|');ax[0,1].plot(t_ms,np.abs(lo),lw=.7,label='|line -R/2|')
ax[0,1].set_title('Sync lock acquires and HOLDS');ax[0,1].set_xlabel('ms');ax[0,1].legend(fontsize=8)
# (3) recovered carrier tracks 2*theta_c
tcs=np.linspace(0,1.4,15); rec=[]
for tc in tcs:
    zz,NN,_=gen_msk(bits,theta_c=tc,snr_db=20,seed=5);_,h,l,_,_=debuda_rx(zz,NN,npre)
    s0=int(400*sps); ph=np.angle(np.mean(h[s0:])); rec.append(ph)
rec=np.unwrap(np.array(rec)-rec[0]); ax[1,0].plot(tcs,rec,'o-',ms=4,label='recovered')
ax[1,0].plot(tcs,2*tcs,'k--',lw=1,label='2·θ_c (ideal)')
ax[1,0].set_title('Carrier recovery: line phase = 2·θ_c');ax[1,0].set_xlabel('injected θ_c (rad)');ax[1,0].set_ylabel('recovered phase step');ax[1,0].legend(fontsize=8)
# (4) BER vs SNR (non-coherent path that works)
snrs=[6,8,10,12,15,20,25];bers=[]
for snr in snrs:
    zz,NN,_=gen_msk(bits,theta_c=0.9,snr_db=snr,seed=5);_,_,_,th2,tp2=debuda_rx(zz,NN,npre)
    _,bnc=detect(zz,NN,th2,tp2,nsym)
    sl=slice(npre+5,nsym-5);e=bnc[sl];t=bits[sl];m=~np.isnan(e)
    bers.append(min(np.mean(e[m]!=t[m]),np.mean((-e[m])!=t[m])))
ax[1,1].semilogy(snrs,np.maximum(bers,1e-5),'o-');ax[1,1].set_title('End-to-end BER (recovered clock+detect)');ax[1,1].set_xlabel('SNR (dB)');ax[1,1].set_ylabel('BER');ax[1,1].grid(alpha=.3,which='both')
fig.tight_layout();fig.savefig('/mnt/user-data/outputs/debuda_golden_model.png',dpi=110)
import shutil; shutil.copy('debuda_full.py','/mnt/user-data/outputs/debuda_rx_model.py')
print("saved figure + model script")
