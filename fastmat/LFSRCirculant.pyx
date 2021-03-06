# -*- coding: utf-8 -*-
#cython: boundscheck=False, wraparound=False
'''
  fastmat/LfsrConv.pyx
 -------------------------------------------------- part of the fastmat package

  Circular Convolution matrix for sequence generated by Linear Feedback Shift
  Register (LFSR) with certain configuration.


  Author      : wcw
  Introduced  : 2017-07-24
 ------------------------------------------------------------------------------

   Copyright 2016 Sebastian Semper, Christoph Wagner
       https://www.tu-ilmenau.de/ems/

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

 ------------------------------------------------------------------------------
'''
from libc.stdlib cimport malloc, free

import numpy as np
cimport numpy as np

from .Matrix cimport Matrix
from .Hadamard cimport Hadamard
from .core.types cimport *
from .core.cmath cimport *

cdef inline np.int8_t lfsrOutBit(lfsrReg_t state) nogil:
    return (-1 if state & 1 else 1)

cdef inline lfsrReg_t lfsrGenStep(lfsrReg_t state, lfsrReg_t taps,
                                  lfsrReg_t mask) nogil:
    cdef lfsrReg_t tmp = state & taps
    tmp ^= tmp >> 1
    tmp ^= tmp >> 2
    tmp = (tmp & 0x11111111) * 0x11111111
    if tmp & 0x10000000:
        state |= mask

    return state >> 1

cdef inline lfsrReg_t lfsrTapStep(lfsrReg_t state, lfsrReg_t taps,
                                  lfsrReg_t mask) nogil:
    state = state << 1
    if (state & mask) != 0:
        state = state ^ (taps | mask)

    return state

################################################################################
################################################## class Hadamard
cdef class LFSRCirculant(Matrix):

    ############################################## class properties
    # vecC - Property (read-only)
    # Return the sequence defining the circular convolution.
    property vecC:
        def __get__(self):
            return (self._getVecC() if self._vecC is None
                    else self._vecC)

    ############################################## class properties
    # states - Property (read-only)
    # Return the internal register states during the sequence.
    property states:
        def __get__(self):
            return (self._getStates() if self._states is None
                    else self._states)

    # size - Property (read-only)
    # Return the length of the sequence generated
    property size:
        def __get__(self):
            return self._regSize

    # taps - Property (read-only)
    # Return the tap positions of the register
    property taps:
        def __get__(self):
            return (self._regTaps)

    # resetState - Property (read-only)
    # Return the reset state of the LFSR
    property resetState:
        def __get__(self):
            return (self._resetState)

    ############################################## class methods
    def __init__(self, int regSize, lfsrReg_t taps,
                 lfsrReg_t resetState=0xFFFFFFFF, lfsrReg_t length=0):
        '''Initialize Matrix instance'''

        cdef lfsrReg_t mask = 1 << regSize

        # determine register size (determines order of embedded Hadamard)
        self._regTaps = taps
        self._regSize = regSize
        self._resetState = resetState & (mask - 1)

        if self._regSize > 31 or self._regSize < 1:
            raise ValueError("Register sizes only supported from 1 to 31.")

        if self._regTaps >= mask:
            raise ValueError("Tap positions exceeding register size.")

        if self._regTaps == 0:
            raise ValueError("Register must feature at least one feedback tap.")

        if self._resetState == 0:
            raise ValueError("Register reset state must be non-zero.")

        assert length < mask, "Sequence length exceeded register capacity."

        # generate embedded Hadamard matrix
        self._content = (Hadamard(self._regSize), )

        # determine matrix size (square) from the specified amount of steps to
        # take. If no count was given, determine it from the maximal register
        # cycle length for the given polynomial and start value by construction
        # of the determining sequence vector
        cdef lfsrReg_t state = self._resetState
        if length == 0:
            state = lfsrGenStep(self._resetState, taps, mask)
            length = 1

            while state != self.resetState:
                state = lfsrGenStep(state, taps, mask)
                length += 1
                if length >= mask or state == 0:
                    raise ValueError(
                        "Register configuration produces invalid sequence.")

        if length <= 1:
            raise ValueError("Register produces static output.")

        # set properties of matrix
        self._initProperties(length, length, np.int8,
                             cythonCall=True)

    ############################################## class property override
    cpdef object _getItem(self, intsize idxN, intsize idxM):
        return self.vecC[(idxN - idxM) % self.numN]

    cpdef np.ndarray _getCol(self, intsize idx):
        '''Return selected columns of self.array'''
        cdef np.ndarray arrRes = _arrEmpty(
            1, self.numN, 0, self._info.dtype[0].typeNum)
        self._roll(arrRes, idx)
        return arrRes

    cpdef np.ndarray _getRow(self, intsize idx):
        '''Return selected rows of self.array'''
        cdef np.ndarray arrRes = _arrEmpty(
            1, self.numN, 0, self._info.dtype[0].typeNum)
        self._roll(arrRes[::-1], self.numN - idx - 1)
        return arrRes

    cpdef Matrix _getNormalized(self):
        return self * np.float32(1. / np.sqrt(self.numN))

    ############################################## class property override
    cpdef tuple _getComplexity(self):
        cdef float complexity = 2 * self._content[0].numN + 2 * self.numN
        return (complexity, complexity)

    ############################################## class core methods
    cdef void _roll(self, np.ndarray vecOut, intsize shift):
        '''Return self.vecC rolled by 'shift' elements.'''
        if shift == 0:
            vecOut[:] = self.vecC
        else:
            vecOut[:shift] = self.vecC[self.numN - shift:]
            vecOut[shift:] = self.vecC[:self.numN - shift]

    cdef np.ndarray _getStates(self):
        cdef intsize nn
        cdef np.ndarray arrStates
        cdef lfsrReg_t[:] mvStates

        cdef nptype typeStates = np.dtype(np.uint32).type_num
        cdef lfsrReg_t mask = 1 << self._regSize
        cdef lfsrReg_t taps = self._regTaps
        cdef lfsrReg_t state = self._resetState

        arrStates = _arrEmpty(1, self.numN, 1, typeStates)
        mvStates = arrStates
        for nn in range(self.numN):
            mvStates[nn] = state & (mask - 1)
            state = lfsrGenStep(state, taps, mask)

        self._states = arrStates
        return arrStates

    cdef np.ndarray _getVecC(self):
        cdef lfsrReg_t mask = 1 << self._regSize
        cdef lfsrReg_t taps = self._regTaps
        cdef lfsrReg_t state = self._resetState
        cdef intsize nn

        cdef np.ndarray arrRes
        cdef np.int8_t[:] mvRes
        cdef nptype typeElement = np.dtype(np.int8).type_num

        arrRes = _arrEmpty(1, self.numN, 1, typeElement)
        mvRes = arrRes
        for nn in range(self.numN):
            mvRes[nn] = lfsrOutBit(state)
            state = lfsrGenStep(state, taps, mask)

        self._vecC = arrRes
        return self._vecC

    cdef void _core(self, np.ndarray arrIn, np.ndarray arrOut,
                    bint flipIn, bint flipOut):

        cdef intsize ii, nn, N = arrIn.shape[0], M = arrIn.shape[1]
        cdef lfsrReg_t state, mask  = 1 << self._regSize
        cdef lfsrReg_t taps         = self._regTaps
        cdef np.ndarray arrData
        cdef SLICE_s slcIn, slcData, slcOut

        # initialize data Array, no zero init required for maximum length seqs
        if N == mask - 1:
            arrData = _arrEmpty(2, mask, M, _getNpType(arrIn), False)
        else:
            arrData = _arrZero(2, mask, M, _getNpType(arrIn), False)

        _arrInitSlice(arrIn, 1, &slcIn)
        _arrInitSlice(arrOut, 1, &slcOut)
        _arrInitSlice(arrData, 1, &slcData)

        # ensure the first element of each vector in arrData is zero
        _arrZeroSlice(&slcData, 0)

        # flipping the arrays achieves circulant shape without actually shifting
        # anything (the original algorithm computes deconvolution which builds
        # an Hankel-like matrix with the sequence elements along anti-diagonals)
        # For the conversion to take place flip the input array during the
        # forward, and the output array during the backward transform.
        # Note, that the flip can be efficiently realized by twiddling around
        # with row indexing

        # apply input permutation P(c->g) from arrIn to arrData (through slices)
        # reset state of address register G resembles sequence start point
        state = self._resetState

        # copy first element from each imput vector to Hadamard transform input
        # data position denoted by the register's start value (copy row to row)
        # then, copy remaining elements (flip them if requested by flipIn)
        _arrCopySlice(&slcData, state, &slcIn, 0)
        # and now for something completely different: addressing hack!
        # to flip the input we can fiddle around with the array base pointer
        # and its strides. Inverting the slice-stride (keeping row distance but
        # changing direction of traversal) and setting the base pointer to the
        # first element AFTER the array achieves what we want.
        # However, index 0 will be mapped directly to the can as it literally
        # starts after the array data. After that however indexing begins with
        # the last row for index 1.
        if flipIn:
            slcIn.base += slcIn.numSlices * slcIn.strideSlice
            slcIn.strideSlice = -slcIn.strideSlice

        for nn in range(1, N):
            state = lfsrGenStep(state, taps, mask)
            _arrCopySlice(&slcData, state, &slcIn, nn)

        # apply hadamard-walsh transform from arrData to arrData
        arrData = self._content[0].forward(arrData)

        # reinit slice as arrData has changed
        _arrInitSlice(arrData, 1, &slcData)

        # apply output permutation P(r->t) fromm arrData to arrOut (slices!)
        # reset state for address register T must always be 1 (unclear in paper)
        state = 1

        # copy elements from Hadamard transform output denoted by the Tap
        # register's start value to first element of result (copy row to row)
        # then, copy remaining elements (flip them if requested by flipOut)
        _arrCopySlice(&slcOut, 0, &slcData, state)

        # same addressing hack as above
        if flipOut:
            slcOut.base += slcOut.numSlices * slcOut.strideSlice
            slcOut.strideSlice = -slcOut.strideSlice

        for nn in range(1, N):
            state = lfsrTapStep(state, taps, mask)
            _arrCopySlice(&slcOut, nn, &slcData, state)

    ############################################## class forward / backward
    cpdef _forwardC(self, np.ndarray arrX, np.ndarray arrRes,
                    ftype typeX, ftype typeRes):
        '''
        Calculate the forward transform of this matrix.
        '''
        # dispatch input ndarray to type specialization
        self._core(arrX, arrRes, True, False)

    cpdef _backwardC(self, np.ndarray arrX, np.ndarray arrRes,
                     ftype typeX, ftype typeRes):
        '''
        Calculate the backward transform of this matrix.
        '''
        # dispatch input ndarray to type specialization
        self._core(arrX, arrRes, False, True)

    ############################################### class reference
    cpdef np.ndarray _reference(self):
        '''
        Return an explicit representation of the matrix without using
        any fastmat code.
        '''
        cdef np.ndarray arrRes, vecSequence
        cdef np.int8_t[:] mvSequence
        cdef int ii, state, taps, mask, tmp, cnt

        state = self.resetState
        taps = self.taps
        mask = 1 << self.size
        vecSequence = np.empty((self.numN, ), dtype=np.int8)
        mvSequence = vecSequence
        for ii in range(self.numN):
            mvSequence[ii] = (state & 1) * -2 + 1

            tmp = state & taps
            cnt = 0
            while tmp:
                cnt ^= 1
                tmp &= tmp - 1

            if cnt:
                state |= mask

            state >>= 1

        arrRes = np.empty((self.numN, self.numN), dtype=self.dtype)
        for ii in range(self.numN):
            arrRes[:, ii] = np.roll(vecSequence, ii)

        return arrRes

    ############################################## class inspection, QM
    def _getTest(self):
        from .inspect import TEST, dynFormat
        return {
            TEST.COMMON: {
                # define matrix sizes and parameters
                'size'          : 4,
                'taps'          : TEST.Permutation([0x9, 0x7]),
                'start'         : TEST.Permutation([0x5, 0x1]),
                'length'        : (lambda param: (15 if param['taps'] == 0x9
                                                  else 7)),
                TEST.NUM_N      : 'length',
                TEST.NUM_M      : TEST.NUM_N,

                # define constructor for test instances and naming of test
                TEST.OBJECT     : LFSRCirculant,
                TEST.INITARGS   : ['size', 'taps', 'start'],
                TEST.NAMINGARGS : dynFormat("%d:%x=%x", 'size', 'taps', 'start')
            },
            TEST.CLASS: {},
            TEST.TRANSFORMS: {}
        }

    def _getBenchmark(self):
        from .inspect import BENCH

        # specify tap configurations for various maximum-length-sequences
        db = {1: [0x1],         2: [0x3],           3: [0x3],
              4: [0x9],         5: [0x05],          6: [0x21],
              7: [0x09],        8: [0xC3],          9: [0x011],
              10: [0x081],      11: [0x303],        12: [0xC11],
              13: [0x0C41],     14: [0x1803],       15: [0x4001],
              16: [0xA011],     17: [0x04001],      18: [0x00801],
              19: [0x64001],    20: [0x20001],      21: [0x080001],
              22: [0x200001],   23: [0x040001],     24: [0xC20001],
              25: [0x0400001],  26: [0x3100001],    27: [0x6400001],
              28: [0x2000001],  29: [0x08000001],   30: [0x30000081],
              31: [0x10000001]}

        return {
            BENCH.COMMON: {
                BENCH.FUNC_GEN  : (lambda c: LFSRCirculant(c, *db[c])),
                BENCH.FUNC_SIZE : (lambda c: (2 ** c) - 1),
                BENCH.FUNC_STEP : (lambda c: c + 1),
            },
            BENCH.FORWARD: {},
            BENCH.SOLVE: {},
            BENCH.OVERHEAD: {},
            BENCH.DTYPES: {
                BENCH.FUNC_GEN  : (lambda c, dt: LFSRCirculant(c, *db[c]))
            }
        }

    def _getDocumentation(self):
        from .inspect import DOC
        return DOC.SUBSECTION(
            r'Circulant Matrix of Linear Shift Register Sequence ' +
            r'(\texttt{fastmat.LFSRCirculant})',
            DOC.SUBSUBSECTION(
                'Definition and Interface',
                r"""
Linear Feedback Shift Registers (LFSR) as implemented in this class are finite
state machines generating sequences of symbols from the finite field
$F=[-1, +1]$. A shift register of size $N$ is a cascade of $N$ storage elements
$a_n$ for $n = 0,\dots,N-1$, each holding one symbol of $F$. The state of the
shift register is defined by the states of $a_0,\dots,a_{N-1}$.
\cite{lfsr_golomb1967}

The next state of the register is generated from the current state by moving
the contents of each storage element to the next lower index by setting
$a_{n-1} = a_n$ for $n \geq 1$, hence the name shift register. The element
$a_0$ of the current state is discarded completely in the next state. A subset
$T$ of all storage elements with cardinality of 1 or greater is used for
generating the next symbol $a_{N-1}$ by multiplication within $F$. $T$ is
called the tap configuration of the shift register.

The output sequence of the register is the sequence of symbols $a_0$ for each
state of the register. When the shift register repeats one of its previous
states after $L$ state transistions, the output sequence also repeats and
thus is periodic with a length $L$. Evaluation of the sequence starts with
all storage elements set to an initial state $I$. Only periodic sequences of
length $L > 1$ are considered if they also repeat all states including the
initial state and thus form a hamilton circle an the graph corresponding to
the chosen shift register size $N$ and tap configuration $T$.

Instanciation of this matrix class requires supplying the requested register
size $N$, the tap configuration and the initial state. The latter two are
required to be supplied as binary words of up to $N$ bits. A one bit on position
$i$ in the tap configuration adds $a_i$ as \emph{feedback tap} to $T$. At least
one feedback tap must be supplied. The bits in the given initial state word $r$
will be mapped to the initial register state, where $r_n = 0$ sets $a_n = +1$
and $r_n = 1$ sets $a_n = -1$. If no $r$ is given, it is assumed to be
all-ones.""",
                DOC.SNIPPET('# import the package',
                            'import fastmat as fm',
                            '',
                            '# construct the parameter',
                            'size = 4',
                            'taps = 0b1001',
                            'initial = 0b1010',
                            '',
                            '# construct the matrix',
                            'L = fm.LFSRCirculant(size, taps, initial)',
                            's = L.vecC',
                            caption=r"""
This yields a Circulant matrix where the column-definition vector is the output
of a LFSR of size 4, which is configured to generate a maximum length sequence
of length 15 and a cyclic shift corresponding to the given initial state.
\[\bm s = [+1, -1, +1, -1, -1, +1, +1, -1, +1, +1, +1, -1, -1, -1, -1]\]
\[\bm L = \left(\begin{array}{ccccc}
    +1 &   -1   & -1 &        & -1 \\
    -1 &   +1   & -1 & \dots  & +1 \\
    +1 &   -1   & +1 &        & -1 \\
       & \vdots &    & \ddots &    \\
    -1 &   -1   & -1 &        & +1 \\
\end{array}\right)\]"""),
                r"""
This class depends on \texttt{Hadamard}."""
            ),
            DOC.SUBSUBSECTION(
                'Performance Benchmarks', r"""
All benchmarks were performed on various maximum-length sequences of register
size $k$, where $n = 2^k - 1$.""",
                DOC.PLOTFORWARD(),
                DOC.PLOTFORWARDMEMORY(),
                DOC.PLOTSOLVE(),
                DOC.PLOTOVERHEAD(),
                DOC.PLOTTYPESPEED()
            ),
            DOC.BIBLIO(
                lfsr_golomb1967=DOC.BIBITEM(
                    'Simon W. Golomb',
                    'Shift Register Sequences',
                    'Holden-Day, Inc. 1967')
            )
        )
