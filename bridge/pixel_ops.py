"""Row-parallel CPU kernels for full-resolution, pointwise RGB operations."""

import math

import numpy as np
from numba import njit, prange


# Small previews can use the existing vectorized operations immediately,
# including on the first launch, before Numba has populated its disk cache.
LARGE_IMAGE = 512 * 1024


@njit(inline="always")
def clamp01(value):
    return min(max(value, 0.), 1.)


@njit(cache=True, parallel=True, nogil=True)
def trilinear(rgb, table):
    output = np.empty(rgb.shape, np.float32)
    last = table.shape[0] - 1
    for y in prange(rgb.shape[0]):
        for x in range(rgb.shape[1]):
            # Invalid coordinates must propagate to output validation instead
            # of becoming an unchecked native array index.
            red, green, blue = rgb[y,x,0], rgb[y,x,1], rgb[y,x,2]
            if not (math.isfinite(red) and math.isfinite(green) and math.isfinite(blue)):
                output[y,x,:] = np.nan
                continue
            r = clamp01(float(red)) * last
            g = clamp01(float(green)) * last
            b = clamp01(float(blue)) * last
            i,j,k = min(int(r),last-1),min(int(g),last-1),min(int(b),last-1)
            dr,dg,db = r-i,g-j,b-k
            for c in range(3):
                # Cast table values to double before subtraction: scipy's
                # reference interpolation accumulates in double precision.
                v000,v001 = np.float64(table[i,j,k,c]),np.float64(table[i,j,k+1,c])
                v010,v011 = np.float64(table[i,j+1,k,c]),np.float64(table[i,j+1,k+1,c])
                v100,v101 = np.float64(table[i+1,j,k,c]),np.float64(table[i+1,j,k+1,c])
                v110,v111 = np.float64(table[i+1,j+1,k,c]),np.float64(table[i+1,j+1,k+1,c])
                low = (v000*(1-db)+v001*db)*(1-dg)+(v010*(1-db)+v011*db)*dg
                high = (v100*(1-db)+v101*db)*(1-dg)+(v110*(1-db)+v111*db)*dg
                output[y,x,c] = low*(1-dr)+high*dr
    return output


@njit(inline="always")
def decode(value, prophoto):
    if prophoto:
        return value/16 if value < 16/512 else value**1.8
    return value/12.92 if value <= .0031308*12.92 else ((value+.055)/1.055)**2.4


@njit(inline="always")
def encode(value, prophoto):
    if prophoto:
        return value*16 if value < 1/512 else value**(1/1.8)
    return value*12.92 if value <= .0031308 else 1.055*value**(1/2.4)-.055


@njit(inline="always")
def exposure(value, gain, power_gain, prophoto):
    if gain == 1:
        return value
    cut = 16/512 if prophoto else .0031308*12.92
    if value <= cut and value*gain <= cut:
        return value*gain
    offset = 0. if prophoto else .055
    power_result = (value+offset)*power_gain-offset
    if value >= cut and power_result > cut:
        return power_result
    return encode(decode(value, prophoto)*gain, prophoto)


@njit(inline="always")
def curve(value, nodes, count):
    if not count:
        return value
    if value <= nodes[0,0]:
        return nodes[0,1]
    if value >= nodes[count-1,0]:
        return nodes[count-1,1]
    left,right=0,count-1
    while right-left>1:
        middle=(left+right)//2
        if nodes[middle,0] < value:
            left=middle
        else:
            right=middle
    mix=(value-nodes[left,0])/(nodes[right,0]-nodes[left,0])
    return nodes[left,1]+mix*(nodes[right,1]-nodes[left,1])


@njit(cache=True, parallel=True, nogil=True)
def grade_pixels(image, weights, prophoto, settings, curves, counts, shifts, zoned):
    gain,contrast,brightness,shadows,highlights,black,span,saturation=settings
    power_gain = gain**(1/(1.8 if prophoto else 2.4))
    out=np.empty_like(image)
    for y in prange(image.shape[0]):
        for x in range(image.shape[1]):
            r=exposure(clamp01(np.float64(image[y,x,0])),gain,power_gain,prophoto)
            g=exposure(clamp01(np.float64(image[y,x,1])),gain,power_gain,prophoto)
            b=exposure(clamp01(np.float64(image[y,x,2])),gain,power_gain,prophoto)
            tone=brightness
            if shadows or highlights:
                lum=clamp01(r*weights[0]+g*weights[1]+b*weights[2])
                tone+=shadows*(1-lum)**2+highlights*lum**2
            r=((r-.5)*contrast+.5+tone-black)/span
            g=((g-.5)*contrast+.5+tone-black)/span
            b=((b-.5)*contrast+.5+tone-black)/span
            if saturation!=1:
                grey=r*weights[0]+g*weights[1]+b*weights[2]
                r,g,b=grey+(r-grey)*saturation,grey+(g-grey)*saturation,grey+(b-grey)*saturation
            r=curve(curve(r,curves[0],counts[0]),curves[1],counts[1])
            g=curve(curve(g,curves[0],counts[0]),curves[2],counts[2])
            b=curve(curve(b,curves[0],counts[0]),curves[3],counts[3])
            if counts[4]:
                lum=clamp01(r*weights[0]+g*weights[1]+b*weights[2])
                lift=curve(lum,curves[4],counts[4])-lum
                r,g,b=r+lift,g+lift,b+lift
            if zoned:
                lum=clamp01(r*weights[0]+g*weights[1]+b*weights[2])
                shadow=max(0.,1-2*lum)
                high=max(0.,2*lum-1)
                mid=1-shadow-high
                r+=shifts[0,0]+shadow*shifts[1,0]+mid*shifts[2,0]+high*shifts[3,0]
                g+=shifts[0,1]+shadow*shifts[1,1]+mid*shifts[2,1]+high*shifts[3,1]
                b+=shifts[0,2]+shadow*shifts[1,2]+mid*shifts[2,2]+high*shifts[3,2]
            out[y,x,0],out[y,x,1],out[y,x,2]=clamp01(r),clamp01(g),clamp01(b)
    return out


@njit(cache=True, parallel=True, nogil=True)
def place_pixels(image, weights, prophoto, shadows, highs):
    out=np.empty_like(image)
    for y in prange(image.shape[0]):
        for x in range(image.shape[1]):
            r=decode(max(0.,np.float64(image[y,x,0])),prophoto)
            g=decode(max(0.,np.float64(image[y,x,1])),prophoto)
            b=decode(max(0.,np.float64(image[y,x,2])),prophoto)
            ev=math.log2(max(1.e-9,r*weights[0]+g*weights[1]+b*weights[2])/.18)
            lift= -shadows*math.expm1(-max(-ev-1,0.)/shadows) if shadows else 0.
            pull= -highs*math.expm1(-max(ev-1,0.)/highs) if highs else 0.
            gain=2**(lift-pull)
            out[y,x,0]=clamp01(encode(r*gain,prophoto))
            out[y,x,1]=clamp01(encode(g*gain,prophoto))
            out[y,x,2]=clamp01(encode(b*gain,prophoto))
    return out


@njit(cache=True, parallel=True, nogil=True)
def silver_pixels(image, weights, prophoto):
    out=np.empty_like(image)
    for y in prange(image.shape[0]):
        for x in range(image.shape[1]):
            lum=0.
            for c in range(3):
                lum+=weights[c]*decode(max(np.float64(image[y,x,c]),0.),prophoto)
            out[y,x,:]=encode(lum,prophoto)
    return out


@njit(cache=True, parallel=True, nogil=True)
def quantize(image, data, max_code):
    """Validate and quantize straight to the destination without a full float copy."""
    invalid = 0
    scale = np.float32(max_code)
    for y in prange(image.shape[0]):
        row_invalid = 0
        for x in range(image.shape[1]):
            for c in range(3):
                v = image[y,x,c]
                if not math.isfinite(v):
                    row_invalid = 1
                    v = np.float32(0)
                v = min(max(v,np.float32(0)),np.float32(1))
                data[y,x,c] = np.rint(v*scale)
        invalid += row_invalid
    return invalid == 0


def prime():
    """Populate the project-local Numba cache during setup, before the first export."""
    weights=np.array([.2126,.7152,.0722])
    curves=np.zeros((5,256,2),np.float64)
    counts=np.zeros(5,np.int32)
    shifts=np.zeros((4,3),np.float64)
    settings=(1.,1.,0.,0.,0.,0.,1.,1.)
    for dtype in (np.float32,np.float64):
        sample=np.zeros((2,2,3),dtype=dtype)
        if dtype is np.float32:
            trilinear(sample,np.zeros((2,2,2,3),np.float32))
        grade_pixels(sample,weights,False,settings,curves,counts,shifts,False)
        place_pixels(sample,weights,False,1.,1.)
        silver_pixels(sample,weights,False)
        for bits,stored in ((8,np.uint8),(16,np.uint16)):
            quantize(sample,np.empty(sample.shape,stored),2**bits-1)
