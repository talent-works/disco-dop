
cdef class ChartItem:
	def __init__(self, label, vec):
		self.label = label
		self.vec = vec
	def __hash__(ChartItem self):
		cdef long h
		# juxtapose bits of label and vec, rotating vec if > 33 words
		h = self.label ^ (self.vec << 31UL) ^ (self.vec >> 31UL)
		return -2 if h == -1 else h
	def __richcmp__(ChartItem self, ChartItem other, int op):
		if op == 2: return self.label == other.label and self.vec == other.vec
		elif op == 3: return self.label != other.label or self.vec != other.vec
		elif op == 5: return self.label >= other.label or self.vec >= other.vec
		elif op == 1: return self.label <= other.label or self.vec <= other.vec
		elif op == 0: return self.label < other.label or self.vec < other.vec
		elif op == 4: return self.label > other.label or self.vec > other.vec
	def __nonzero__(ChartItem self):
		return self.label != 0 and self.vec != 0
	def __repr__(ChartItem self):
		return "ChartItem(%d, %s)" % (self.label, bin(self.vec))

cdef class Edge:
	def __init__(self, score, inside, prob, left, right):
		self.score = score; self.inside = inside; self.prob = prob
		self.left = left; self.right = right
	def __hash__(self):
		cdef long h
		#self._hash = hash((inside, prob, left, right))
		# this is the hash function used for tuples, apparently
		h = (1000003UL * 0x345678UL) ^ <long>self.inside
		h = (1000003UL * h) ^ <long>self.prob
		h = (1000003UL * h) ^ (<ChartItem>self.left).vec
		h = (1000003UL * h) ^ (<ChartItem>self.left).label
		h = (1000003UL * h) ^ (<ChartItem>self.right).vec
		h = (1000003UL * h) ^ (<ChartItem>self.right).label
		return -2 if h == -1 else h
	def __richcmp__(Edge self, other, int op):
		# the ordering only depends on the estimate / inside score
		if op == 0: return self.score < (<Edge>other).score
		elif op == 1: return self.score <= (<Edge>other).score
		# (in)equality compares all elements
		# boolean trick: equality and inequality in one expression i.e., the
		# equality between the two boolean expressions acts as biconditional
		elif op == 2 or op == 3:
			return (op == 2) == (
				self.score == (<Edge>other).score
				and self.inside == (<Edge>other).inside
				and self.prob == (<Edge>other).prob
				and self.left == (<Edge>other).left
				and self.right == (<Edge>other).right)
		elif op == 4: return self.score > other.score
		elif op == 5: return self.score >= other.score
	def __repr__(self):
		return "Edge(%g, %g, %g, %r, %r)" % (
				self.score, self.inside, self.prob, self.left, self.right)

cdef class RankedEdge:
	def __cinit__(self, ChartItem head, Edge edge, int j1, int j2):
		self.head = head; self.edge = edge
		self.left = j1; self.right = j2
	def __hash__(self):
		cdef long h
		#h = hash((head, edge, j1, j2))
		h = (1000003UL * 0x345678UL) ^ hash(self.head)
		h = (1000003UL * h) ^ hash(self.edge)
		h = (1000003UL * h) ^ self.left
		h = (1000003UL * h) ^ self.right
		if h == -1: h = -2
		return h
	def __richcmp__(self, RankedEdge other, int op):
		if op == 2 or op == 3:
			return (op == 2) == (
				self.left == other.left
				and self.right == other.right
				and self.head == other.head
				and self.edge == other.edge)
		else:
			raise NotImplemented
	def __repr__(self):
		return "RankedEdge(%r, %r, %d, %d)" % (
					self.head, self.edge, self.left, self.right)

cdef class Terminal:
	def __init__(self, lhs, rhs1, rhs2, word, prob):
		self.lhs = lhs; self.rhs1 = rhs1; self.rhs2 = rhs2
		self.word = word; self.prob = prob

cdef class Rule:
	def __init__(self, lhs, rhs1, rhs2, args, lengths, prob):
		self.lhs = lhs; self.rhs1 = rhs1; self.rhs2 = rhs2
		self.args = args; self.lengths = lengths
		self._args = self.args._I; self._lengths = self.lengths._H
		self.prob = prob
	
cdef struct DTree:
	void *rule
	unsigned long long vec
	bint islexical
	DTree *left, *right

cdef DTree new_DTree(Rule rule, unsigned long long vec, bint islexical, DTree left, DTree right):
	return DTree(<void *>rule, vec, islexical, &left, &right)

# some helper functions that only serve to bridge cython & python code
cpdef inline unsigned int getlabel(ChartItem a):
	return a.label
cpdef inline unsigned long long getvec(ChartItem a):
	return a.vec
cpdef inline double getscore(Edge a):
	return a.score
cpdef inline dict dictcast(d):
	return <dict>d
cpdef inline ChartItem itemcast(i):
	return <ChartItem>i
cpdef inline Edge edgecast(e):
	return <Edge>e
