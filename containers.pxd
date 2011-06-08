from array cimport array

cdef class ChartItem:
	cdef int label
	cdef unsigned long vec
	cdef long _hash

cdef class Edge:
	cdef double inside
	cdef double prob
	cdef ChartItem left
	cdef ChartItem right
	cdef long _hash

cdef class Terminal:
	cdef public int lhs
	cdef public int rhs1
	cdef public int rhs2
	cdef public unicode word
	cdef public double prob

cdef class Rule:
	cdef public int lhs
	cdef public int rhs1
	cdef public int rhs2
	cdef public array args
	cdef public array lengths
	cdef public double prob