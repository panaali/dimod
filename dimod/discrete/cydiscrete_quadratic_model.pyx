# Copyright 2020 D-Wave Systems Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

import collections.abc as abc

cimport cython

from cython.operator cimport preincrement as inc, dereference as deref
from libcpp.algorithm cimport lower_bound, upper_bound
from libcpp.pair cimport pair

import numpy as np

# this is the same as in dimod/utils.h but cython cannot recognize that one
cdef bint comp_v(pair[CaseIndex, Bias] ub, Bias v):
    return ub.first < v


cdef class cyDiscreteQuadraticModel:

    def __init__(self):
        self.case_starts_.push_back(0)

        self.dtype = np.float64
        self.case_dtype = np.int64

    @property
    def adj(self):
        return self.adj_

    cpdef Py_ssize_t add_variable(self, Py_ssize_t num_cases) except -1:
        """Add a discrete variable.

        Args:
            num_cases (int): The number of cases in the variable.

        Returns:
            int: The label of the new variable.

        """

        if num_cases <= 0:
            raise ValueError("num_cases must be a positive integer")

        cdef VarIndex v = self.adj_.size()  # index of new variable

        self.adj_.resize(v+1)

        cdef Py_ssize_t i
        for i in range(num_cases):
            self.bqm_.add_variable()

        self.case_starts_.push_back(self.bqm_.num_variables())

        return v

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef Bias[:] energies(self, CaseIndex[:, :] samples):
        
        if samples.shape[1] != self.num_variables():
            raise ValueError("Given sample(s) have incorrect number of variables")

        cdef Py_ssize_t num_samples = samples.shape[0]
        cdef VarIndex num_variables = samples.shape[1]

        cdef Bias[:] energies = np.zeros(num_samples, dtype=self.dtype)

        cdef Py_ssize_t si, vi
        cdef CaseIndex cu, case_u, cv, case_v
        cdef VarIndex u, v
        for si in range(num_samples):  # this could be parallelized
            for u in range(num_variables):
                case_u = samples[si, u]

                if case_u >= self.num_cases(u):
                    raise ValueError("invalid case")

                cu = self.case_starts_[u] + case_u

                energies[si] += self.bqm_.get_linear(cu)

                for vi in range(self.adj_[u].size()):
                    v = self.adj_[u][vi]

                    # we only care about the lower triangle
                    if v > u:
                        break

                    case_v = samples[si, v]

                    cv = self.case_starts_[v] + case_v

                    out = self.bqm_.get_quadratic(cu, cv)

                    if out.second:
                        energies[si] += out.first

        return energies

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def get_linear(self, VarIndex v):

        cdef Py_ssize_t num_cases = self.num_cases(v)

        biases = np.empty(num_cases, dtype=np.float64)
        cdef Bias[:] biases_view = biases

        cdef Py_ssize_t c
        for c in range(num_cases):
            biases_view[c] = self.bqm_.get_linear(self.case_starts_[v] + c)

        return biases

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef Bias get_linear_case(self, VarIndex v, CaseIndex case) except? -45.3:

        # self.num_cases checks that the variable is valid

        if case < 0 or case >= self.num_cases(v):
            raise ValueError("case {} is invalid, variable only supports {} "
                             "cases".format(case, self.num_cases(v)))

        return self.bqm_.get_linear(self.case_starts_[v] + case)

    def get_quadratic(self, VarIndex u, VarIndex v, bint array=False):

        # check that the interaction does in fact exist
        if u < 0 or u >= self.adj_.size():
            raise ValueError("unknown variable")
        if v < 0 or v >= self.adj_.size():
            raise ValueError("unknown variable")

        it = lower_bound(self.adj_[u].begin(), self.adj_[u].end(), v)
        if it == self.adj_[u].end() or deref(it) != v:
            raise ValueError("there is no interaction between given variables")

        cdef CaseIndex ci
        cdef Py_ssize_t case_u, case_v
        cdef Bias[:, :] quadratic_view

        if array:
            # build a numpy array
            quadratic = np.zeros((self.num_cases(u), self.num_cases(v)),
                                 dtype=self.dtype)
            quadratic_view = quadratic

            for ci in range(self.case_starts_[u], self.case_starts_[u+1]):

                span = self.bqm_.neighborhood(ci, self.case_starts_[v])

                while (span.first != span.second and deref(span.first).first < self.case_starts_[v+1]):
                    case_u = ci - self.case_starts_[u]
                    case_v = deref(span.first).first - self.case_starts_[v]
                    quadratic_view[case_u, case_v] = deref(span.first).second

                    inc(span.first)

        else:
            # store in a dict
            quadratic = {}

            for ci in range(self.case_starts_[u], self.case_starts_[u+1]):

                span = self.bqm_.neighborhood(ci, self.case_starts_[v])

                while (span.first != span.second and deref(span.first).first < self.case_starts_[v+1]):
                    case_u = ci - self.case_starts_[u]
                    case_v = deref(span.first).first - self.case_starts_[v]
                    quadratic[case_u, case_v] = deref(span.first).second

                    inc(span.first)

        # todo: support scipy sparse matrices?

        return quadratic

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef Bias get_quadratic_case(self,
                                  VarIndex u, CaseIndex case_u,
                                  VarIndex v, CaseIndex case_v)  except? -45.3:

        if case_u < 0 or case_u >= self.num_cases(u):
            raise ValueError("case {} is invalid, variable only supports {} "
                             "cases".format(case_u, self.num_cases(u)))

        if case_v < 0 or case_v >= self.num_cases(v):
            raise ValueError("case {} is invalid, variable only supports {} "
                             "cases".format(case_v, self.num_cases(v)))


        cdef CaseIndex cu = self.case_starts_[u] + case_u
        cdef CaseIndex cv = self.case_starts_[v] + case_v

        return self.bqm_.get_quadratic(cu, cv).first 

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef Py_ssize_t num_cases(self, Py_ssize_t v=-1) except -1:
        """If v is provided, the number of cases associated with v, otherwise
        the total number of cases in the DQM.
        """
        if v < 0:
            return self.bqm_.num_variables()

        if v >= self.num_variables():
            raise ValueError("unknown variable {}".format(v))

        return self.case_starts_[v+1] - self.case_starts_[v]

    cpdef Py_ssize_t num_variables(self):
        """The number of discrete variables in the DQM."""
        return self.adj_.size()

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef Py_ssize_t set_linear(self, VarIndex v, Bias[:] biases) except -1:

        # self.num_cases checks that the variable is valid

        if biases.shape[0] != self.num_cases(v):
            raise ValueError('Recieved {} bias(es) for a variable of degree {}'
                             ''.format(biases.shape[0], self.num_cases(v)))

        cdef Py_ssize_t c
        for c in range(biases.shape[0]):
            self.bqm_.set_linear(self.case_starts_[v] + c, biases[c])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef Py_ssize_t set_linear_case(self, VarIndex v, CaseIndex case, Bias b) except -1:
        
        # self.num_cases checks that the variable is valid

        if case < 0:
            raise ValueError("case should be a positive integer")
        if case >= self.num_cases(v):
            raise ValueError("case {} is invalid, variable only supports {} "
                             "cases".format(case, self.num_cases(v)))

        self.bqm_.set_linear(self.case_starts_[v] + case, b)

    def set_quadratic(self, VarIndex u, VarIndex v, biases):

        # check that the interaction does in fact exist
        if u < 0 or u >= self.adj_.size():
            raise ValueError("unknown variable")
        if v < 0 or v >= self.adj_.size():
            raise ValueError("unknown variable")

        cdef CaseIndex case_u, case_v
        cdef CaseIndex cu, cv
        cdef Bias bias

        cdef Py_ssize_t num_cases_u = self.num_cases(u)
        cdef Py_ssize_t num_cases_v = self.num_cases(v)

        cdef Bias[:, :] biases_view

        if isinstance(biases, abc.Mapping):
            for (case_u, case_v), bias in biases.items():
                if case_u < 0 or case_u >= num_cases_u:
                    raise ValueError("case {} is invalid, variable only supports {} "
                                     "cases".format(case_u, self.num_cases(u)))

                if case_v < 0 or case_v >= num_cases_v:
                    raise ValueError("case {} is invalid, variable only supports {} "
                                     "cases".format(case_v, self.num_cases(v)))

                cu = self.case_starts_[u] + case_u
                cv = self.case_starts_[v] + case_v

                self.bqm_.set_quadratic(cu, cv, bias)
        else:
            
            biases_view = np.asarray(biases).reshape(num_cases_u, num_cases_v)

            for case_u in range(biases_view.shape[0]):
                cu = self.case_starts_[u] + case_u
                for case_v in range(biases_view.shape[1]):
                     cv = self.case_starts_[v] + case_v

                     bias = biases_view[case_u, case_v]

                     if bias:
                         self.bqm_.set_quadratic(cu, cv, bias)

        # track in adjacency
        low = lower_bound(self.adj_[u].begin(), self.adj_[u].end(), v)
        if low == self.adj_[u].end() or deref(low) != v:
            # need to add
            self.adj_[u].insert(low, v)
            self.adj_[v].insert(
                lower_bound(self.adj_[v].begin(), self.adj_[v].end(), u),
                u)

    cpdef Py_ssize_t set_quadratic_case(self,
                                        VarIndex u, CaseIndex case_u,
                                        VarIndex v, CaseIndex case_v,
                                        Bias bias) except -1:

        # self.num_cases checks that the variables are valid

        if case_u < 0 or case_u >= self.num_cases(u):
            raise ValueError("case {} is invalid, variable only supports {} "
                             "cases".format(case_u, self.num_cases(u)))

        if case_v < 0 or case_v >= self.num_cases(v):
            raise ValueError("case {} is invalid, variable only supports {} "
                             "cases".format(case_v, self.num_cases(v)))


        cdef CaseIndex cu = self.case_starts_[u] + case_u
        cdef CaseIndex cv = self.case_starts_[v] + case_v

        self.bqm_.set_quadratic(cu, cv, bias)

        # track in adjacency
        low = lower_bound(self.adj_[u].begin(), self.adj_[u].end(), v)
        if low == self.adj_[u].end() or deref(low) != v:
            # need to add
            self.adj_[u].insert(low, v)
            self.adj_[v].insert(
                lower_bound(self.adj_[v].begin(), self.adj_[v].end(), u),
                u)
