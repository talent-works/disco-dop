""" Probabilistic CKY parser for monotone, string-rewriting
Linear Context-Free Rewriting Systems. """
from array import array
# python imports
from math import log, exp
from collections import defaultdict
import re, logging, sys
import numpy as np
from agenda import EdgeAgenda, Entry
# cython imports
from cpython cimport PyDict_Contains, PyDict_GetItem
from cpython.array cimport array
cimport numpy as np
from agenda cimport Entry, EdgeAgenda, Agenda
from containers cimport ChartItem, Edge, Grammar, Rule, LexicalRule, \
    UChar, UInt, ULong, ULLong, SmallChartItem, FatChartItem, CFGChartItem, \
	LCFRSEdge, CFGEdge, new_ChartItem, new_Edge, new_CFGChartItem, \
	new_FatChartItem, new_CFGEdge, binrepr as binrepr1
from bit cimport nextset, nextunset, bitcount, bitlength, testbit, testbitint, \
	anextset, anextunset, abitcount, abitlength, ulongset, ulongcpy, setunion
cdef extern from "math.h":
	bint isinf(double x)
	bint isfinite(double x)
cdef extern from "macros.h":
	int BITSIZE
	int BITSLOT(int b)
	ULong BITMASK(int b)
	int BITNSLOTS(int nb)
	void SETBIT(ULong a[], int b)
	ULong TESTBIT(ULong a[], int b)
cdef SmallChartItem NONE = new_ChartItem(0, 0)
np.import_array()
DEF SX = 1
DEF SXlrgaps = 2
DEF SLOTS = 2

def parse(sent, Grammar grammar, tags=None, start=1, bint exhaustive=False,
		list whitelist=None, bint splitprune=False, bint markorigin=False,
		estimates=None, int beamwidth=0):
	""" parse sentence, a list of tokens, optionally with gold tags, and
	produce a chart, either exhaustive or up until the viterbi parse.
	Other parameters:
        - start: integer corresponding to the start symbol that analyses should
            have, e.g., grammar.toid['ROOT']
        - exhaustive: don't stop at viterbi parser, return a full chart
        - whitelist: a whitelist of allowed ChartItems. Anything else is not
            added to the agenda.
        - splitprune: coarse stage used a split-PCFG where discontinuous node
            appear as multiple CFG nodes. Every discontinuous node will result
            in multiple lookups into whitelist to see whether it should be
            allowed on the agenda.
        - markorigin: in combination with splitprune, coarse labels include an
            integer to distinguish components; e.g., CFG nodes NP*0 and NP*1
            map to the discontinuous node NP_2
        - estimates: use context-summary estimates (heuristics, figures of
			merit) to order agenda. should be a tuple with the kind of
			estimates ('SX' or 'SXlrgaps'), and the estimates themselves in a
			4-dimensional numpy matrix. If estimates are not consistent, it is
			no longer guaranteed that the optimal parse will be found.
			experimental.
        - beamwidth: specify the maximum number of items that will be explored
            for each particular span, on a first-come-first-served basis.
            setting to 0 disables this feature. experimental.
	"""
	cdef str label = ''
	cdef dict beam = <dict>defaultdict(int)			#histogram of spans
	cdef dict chart = {}							#the full chart
	cdef list viterbi = [{} for _ in grammar.toid]	#the viterbi probabilities
	cdef EdgeAgenda agenda = EdgeAgenda()			#the agenda
	cdef size_t i
	cdef Rule rule
	cdef LexicalRule terminal
	cdef Entry entry
	cdef LCFRSEdge edge
	cdef SmallChartItem item, sibling, newitem = new_ChartItem(0, 0)
	cdef SmallChartItem goal = new_ChartItem(start, (1ULL << len(sent)) - 1)
	cdef np.ndarray[np.double_t, ndim=4] outside
	cdef double x = 0.0, y = 0.0, score, inside
	cdef signed int length = 0, left = 0, right = 0, gaps = 0
	cdef signed int lensent = len(sent), estimatetype = 0
	cdef UInt blocked = 0, Epsilon = grammar.toid["Epsilon"]
	cdef ULong maxA = 0
	cdef ULLong vec = 0

	if lensent >= sizeof(vec) * 8:
		return parse_longsent(sent, grammar, tags=tags, start=start,
			exhaustive=exhaustive, whitelist=whitelist, splitprune=splitprune,
			markorigin=markorigin, estimates=estimates)
	if estimates is not None:
		estimatetypestr, outside = estimates
		estimatetype = {"SX":SX, "SXlrgaps":SXlrgaps}[estimatetypestr]

	# scan
	for i, w in enumerate(sent):
		recognized = False
		item = new_ChartItem(Epsilon, i)
		if estimates is not None:
			length = 1; left = i; gaps = 0; right = lensent - 1 - i
		for terminal in grammar.lexical.get(w, []):
			# if we are given gold tags, make sure we only allow matching
			# tags - after removing addresses introduced by the DOP reduction
			if (not tags or grammar.tolabel[terminal.lhs] == tags[i]
				or grammar.tolabel[terminal.lhs].startswith(tags[i] + "@")):
				score = terminal.prob
				if estimatetype == SX:
					score += outside[terminal.lhs, left, right, 0]
					if score > 300.0: continue
				elif estimatetype == SXlrgaps:
					score += outside[terminal.lhs, length, left+right, gaps]
					if score > 300.0: continue
				newitem.label = terminal.lhs; newitem.vec = 1ULL << i
				tmp = process_edge(newitem, score, terminal.prob,
					terminal.prob, -1, item, NONE, agenda, chart, viterbi, grammar,
					exhaustive, whitelist, False, markorigin, &blocked)
				#check whether item has not been blocked
				recognized |= newitem is not tmp
				newitem = tmp
		if not recognized and tags and tags[i] in grammar.toid:
			lhs = grammar.toid[tags[i]]
			score = 0.0
			if estimatetype == SX:
				score += outside[lhs, left, right, 0]
				if score > 300.0: continue
			elif estimatetype == SXlrgaps:
				score += outside[lhs, length, left+right, gaps]
				if score > 300.0: continue
			tagitem = new_ChartItem(lhs, 1ULL << i)
			agenda[tagitem] = new_Edge(score, 0.0, 0.0, -1, item, NONE)
			chart[tagitem] = []
			recognized = True
		elif not recognized:
			return chart, NONE, "not covered: '%s'. " % (tags[i] if tags else w)

	# parsing
	while agenda.length:
		entry = agenda.popentry()
		item = <SmallChartItem>entry.key
		edge = <LCFRSEdge>entry.value
		chart[item].append(iscore(edge))
		(<dict>viterbi[item.label])[item] = edge
		if item.label == goal.label and item.vec == goal.vec:
			if not exhaustive: break
		else:
			x = edge.inside

			# unary
			if estimates is not None:
				length = bitcount(item.vec); left = nextset(item.vec, 0)
				gaps = bitlength(item.vec) - length - left
				right = lensent - length - left - gaps
			if beamwidth:
				if beam[item.vec] > beamwidth: continue
				beam[item.vec] += 1
			for i in range(grammar.numrules):
				rule = grammar.unary[item.label][i]
				if rule.rhs1 != item.label: break
				score = inside = x + rule.prob
				if estimatetype == SX:
					score += outside[rule.lhs, left, right, 0]
					if score > 300.0: continue
				elif estimatetype == SXlrgaps:
					score += outside[rule.lhs, length, left+right, gaps]
					if score > 300.0: continue
				newitem.label = rule.lhs; newitem.vec = item.vec
				newitem = process_edge(newitem, score, inside, rule.prob,
					rule.no, item, NONE, agenda, chart, viterbi, grammar,
					exhaustive, whitelist,
					splitprune and grammar.fanout[rule.lhs] != 1,
					markorigin, &blocked)

			# binary left
			for i in range(grammar.numrules):
				rule = grammar.lbinary[item.label][i]
				if rule.rhs1 != item.label: break
				for I, e in (<dict>viterbi[rule.rhs2]).iteritems():
					sibling = <SmallChartItem>I
					if beamwidth:
						if beam[item.vec ^ sibling.vec] > beamwidth: continue
						beam[item.vec ^ sibling.vec] += 1
					if concat(rule, item.vec, sibling.vec):
						newitem.label = rule.lhs
						newitem.vec = item.vec ^ sibling.vec
						y = (<LCFRSEdge>e).inside
						score = inside = x + y + rule.prob
						if estimatetype == SX:
							length = bitcount(newitem.vec)
							left = nextset(newitem.vec, 0)
							right = lensent - length - left
							score += outside[rule.lhs, left, right, 0]
							if score > 300.0: continue
						elif estimatetype == SXlrgaps:
							length = bitcount(newitem.vec)
							left = nextset(newitem.vec, 0)
							gaps = bitlength(newitem.vec) - length - left
							right = lensent - length - left - gaps
							score += outside[rule.lhs, length, left+right, gaps]
							if score > 300.0: continue
						newitem = process_edge(newitem, score, inside,
								rule.prob, rule.no, item, sibling, agenda, chart,
								viterbi, grammar, exhaustive, whitelist,
								splitprune and grammar.fanout[rule.lhs] != 1,
								markorigin, &blocked)

			# binary right
			for i in range(grammar.numrules):
				rule = grammar.rbinary[item.label][i]
				if rule.rhs2 != item.label: break
				for I, e in (<dict>viterbi[rule.rhs1]).iteritems():
					sibling = <SmallChartItem>I
					if beamwidth:
						if beam[sibling.vec ^ item.vec] > beamwidth: continue
						beam[sibling.vec ^ item.vec] += 1
					if concat(rule, sibling.vec, item.vec):
						newitem.label = rule.lhs
						newitem.vec = sibling.vec ^ item.vec
						y = (<LCFRSEdge>e).inside
						score = inside = x + y + rule.prob
						if estimatetype == SX:
							length = bitcount(item.vec)
							left = nextset(item.vec, 0)
							right = lensent - length - left
							score += outside[rule.lhs, left, right, 0]
							if score > 300.0: continue
						elif estimatetype == SXlrgaps:
							length = bitcount(item.vec)
							left = nextset(item.vec, 0)
							gaps = bitlength(item.vec) - length - left
							right = lensent - length - left - gaps
							score += outside[rule.lhs, length, left+right, gaps]
							if score > 300.0: continue
						newitem = process_edge(newitem, score, inside,
								rule.prob, rule.no, sibling, item, agenda, chart,
								viterbi, grammar, exhaustive, whitelist,
								splitprune and grammar.fanout[rule.lhs] != 1,
								markorigin, &blocked)

		if agenda.length > maxA: maxA = agenda.length
		#if agenda.length % 1000 == 0:
		#	logging.debug(("agenda max %d, now %d, items %d (%d labels), "
		#		"edges %d, blocked %d" % (maxA, len(agenda),
		#		len(filter(None, chart.values())), len(filter(None, viterbi)),
		#		sum(map(len, chart.values())), blocked)))
	msg = ("agenda max %d, now %d, items %d (%d labels), edges %d, blocked %d"
		% (maxA, len(agenda), len(filter(None, chart.values())),
		len(filter(None, viterbi)), sum(map(len, chart.values())), blocked))
	if goal in chart: return chart, goal, msg
	else: return chart, NONE, "no parse " + msg

cdef SmallChartItem component = new_ChartItem(0, 0)
cdef inline SmallChartItem process_edge(SmallChartItem newitem, double score,
		double inside, double prob, int ruleno, SmallChartItem left, SmallChartItem right,
		EdgeAgenda agenda, dict chart, list viterbi, Grammar grammar,
		bint exhaustive, list whitelist, bint splitprune, bint markorigin,
		UInt *blocked):
	""" Decide what to do with a newly derived edge. """
	cdef UInt a, b, cnt, label
	cdef bint inagenda
	cdef bint inchart
	cdef list componentlist
	cdef dict componentdict
	# put item in `newitem'; if item ends up in chart, newitem will be replaced
	# by a fresh object, otherwise, it can be re-used.
	inagenda = agenda.contains(newitem)
	inchart = PyDict_Contains(chart, newitem) == 1
	if not inagenda and not inchart:
		#if score > 300.0:
		#	blocked[0] += 1
		#	return newitem
		# check if we need to prune this item
		if whitelist is not None and whitelist[newitem.label] is not None:
			# disc. item to be treated as several split items?
			if splitprune:
				if markorigin: componentlist = <list>(whitelist[newitem.label])
				else: componentdict = <dict>(whitelist[newitem.label])
				component.label = 0
				b = cnt = 0
				a = nextset(newitem.vec, b)
				while a != -1:
					b = nextunset(newitem.vec, a)
					#given a=3, b=6, make bitvector: 1000000 - 1000 = 111000
					component.vec = (1ULL << b) - (1ULL << a)
					if markorigin: componentdict = <dict>(componentlist[cnt])
					if PyDict_Contains(componentdict, component) != 1:
						blocked[0] += 1
						return newitem
					a = nextset(newitem.vec, b)
					cnt += 1
			else:
				label = newitem.label; newitem.label = 0
				if PyDict_Contains(whitelist[label], newitem) != 1:
					#or inside+<double><object>outside > 300.0):
					blocked[0] += 1
					return newitem
				newitem.label = label

		# haven't seen this item before, won't prune, add to agenda
		agenda.setitem(newitem,
				new_Edge(score, inside, prob, ruleno, left, right))
		chart[newitem] = []
	# in agenda (maybe in chart)
	elif not exhaustive and inagenda:
		agenda.setifbetter(newitem,
				new_Edge(score, inside, prob, ruleno, left, right))
	elif (inagenda and inside < (<LCFRSEdge>(agenda.getitem(newitem))).inside):
		# item has lower score, decrease-key in agenda
		# (add old, suboptimal edge to chart if parsing exhaustively)
		chart[newitem].append(iscore(agenda.replace(newitem,
				new_Edge(score, inside, prob, ruleno, left, right))))
	# not in agenda => must be in chart
	elif (not inagenda and inside <
				(<LCFRSEdge>(<dict>viterbi[newitem.label])[newitem]).inside):
		#re-add to agenda because we found a better score.
		#should not happen without estimates!
		agenda.setitem(newitem,
				new_Edge(score, inside, prob, ruleno, left, right))
		logging.warning("WARN: updating score in agenda: %r", newitem)
	elif exhaustive:
		# suboptimal edge
		chart[newitem].append(iscore(
				new_Edge(score, inside, prob, ruleno, left, right)))
	return SmallChartItem.__new__(SmallChartItem)

cdef inline bint concat(Rule rule, ULLong lvec, ULLong rvec):
	"""
	Determine the compatibility of two bitvectors (tuples of spans / ranges)
	according to the given yield function. Ranges should be non-overlapping,
	continuous when they are concatenated, and adhere to the ordering in the
	yield function.
	The yield function is a tuple of tuples with indices indicating from which
	vector the next span should be taken from, with 0 meaning left and 1 right.
	Note that the least significant bit is the lowest index in the vectors,
	which is the opposite of their normal presentation: 0b100 is the last
	terminal in a three word sentence, 0b001 is the first. E.g.,

	>>> lvec = 0b0011; rvec = 0b1000; yieldfunction = ((0,), (1,))
	>>> concat(((0,), (1,)), lvec, rvec)
	True		#discontinuous, non-overlapping, linearly ordered.
	>>> concat(((0, 1),), lvec, rvec)
	False		#lvec and rvec are not contiguous
	>>> concat(((1,), (0,)), lvec, rvec)
	False		#rvec's span should come after lvec's span

	update: yield functions are now encoded in a binary format; cf. containers.pyx
		( (0, 1, 0), (1, 0) ) ==> args: 0b10010     lengths: 0b00101
		NB: note reversal due to the way binary numbers are represented
		the least significant bit (rightmost) corresponds to the lowest
		index in the sentence / constituent (leftmost).
	"""
	if lvec & rvec: return False
	# if the yield function is the concatenation of two elements, and there are
	# no gaps in lvec and rvec, then this should be quicker
	#if 0b10 == rule.lengths: # == rule.args:
	#	lvec |= lvec - 1 # replace trailing zeroes with ones
	#	rvec ^= lvec # combine lvec & rvec
	#	return rvec & (rvec + 1) == 0 # is power of 2?
	cdef ULLong mask = rvec if testbitint(rule.args, 0) else lvec
	cdef size_t n
	for n in range(bitlength(rule.lengths)):
		if testbitint(rule.args, n): # component from right vector
			if rvec & mask == 0: return False # check for expected component
			rvec |= rvec - 1 # trailing 0 bits => 1 bits
			mask = rvec & (~rvec - 1) # everything before first 0 bit => 1 bits
		else: # component from left vector
			if lvec & mask == 0: return False # check for expected component
			lvec |= lvec - 1 # trailing 0 bits => 1 bits
			mask = lvec & (~lvec - 1) # everything before first 0 bit => 1 bits
		# zero out component
		lvec &= ~mask
		rvec &= ~mask
		if testbitint(rule.lengths, n): # a gap
			# check that there is a gap in both vectors
			if (lvec ^ rvec) & (mask + 1): return False
			# increase mask to cover gap
			# get minimum of trailing zero bits of lvec & rvec
			mask = (~lvec & (lvec - 1)) & (~rvec & (rvec - 1))
		mask += 1  # e.g., 00111 => 01000
	# success if we've reached the end of both left and right vector
	return lvec == rvec == 0

cdef FatChartItem FATNONE = new_FatChartItem(0)
def parse_longsent(sent, Grammar grammar, tags=None, start=1,
		bint exhaustive=False, list whitelist=None, bint splitprune=False, bint
		markorigin=False, estimates=None):
	""" Parse a sentence longer than the machine word size. """
	cdef str label = ''
	cdef dict chart = {}							#the full chart
	cdef list viterbi = [{} for _ in grammar.toid]	#the viterbi probabilities
	cdef EdgeAgenda agenda = EdgeAgenda()			#the agenda
	cdef size_t i
	cdef Rule rule
	cdef LexicalRule terminal
	cdef Entry entry
	cdef LCFRSEdge edge
	cdef FatChartItem item, sibling, newitem = new_FatChartItem(0)
	cdef FatChartItem goal
	cdef np.ndarray[np.double_t, ndim=4] outside
	cdef double x = 0.0, y = 0.0, score, inside
	cdef signed int length = 0, left = 0, right = 0, gaps = 0
	cdef signed int lensent = len(sent), estimatetype = 0
	cdef UInt blocked = 0, Epsilon = grammar.toid["Epsilon"]
	cdef ULong maxA = 0
	goal = new_FatChartItem(start)
	ulongset(goal.vec, ~0UL, BITNSLOTS(lensent) - 1)
	goal.vec[BITSLOT(lensent)] = BITMASK(lensent) - 1

	assert len(sent) < (sizeof(goal.vec) * 8), ("input length: %d. max: %d" % (
		lensent, sizeof(goal.vec) * 8))
	if estimates is not None:
		estimatetypestr, outside = estimates
		estimatetype = {"SX":SX, "SXlrgaps":SXlrgaps}[estimatetypestr]

	# scan
	for i, w in enumerate(sent):
		recognized = False
		item = new_FatChartItem(Epsilon)
		item.vec[0] = i
		if estimates is not None:
			length = 1; left = i; gaps = 0; right = lensent - 1 - i
		for terminal in grammar.lexical.get(w, []):
			# if we are given gold tags, make sure we only allow matching
			# tags - after removing addresses introduced by the DOP reduction
			if (not tags or grammar.tolabel[terminal.lhs] == tags[i]
				or grammar.tolabel[terminal.lhs].startswith(tags[i] + "@")):
				score = terminal.prob
				if estimatetype == SX:
					score += outside[terminal.lhs, left, right, 0]
					if score > 300.0: continue
				elif estimatetype == SXlrgaps:
					score += outside[terminal.lhs, length, left+right, gaps]
					if score > 300.0: continue
				newitem.label = terminal.lhs
				SETBIT(newitem.vec, i)
				tmp = process_fatedge(newitem, score, terminal.prob,
					terminal.prob, -1, item, FATNONE, agenda, chart, viterbi,
					grammar, exhaustive, whitelist, False, markorigin, &blocked)
				#check whether item has not been blocked
				recognized |= newitem is not tmp
				newitem = tmp
		if not recognized and tags and tags[i] in grammar.toid:
			lhs = grammar.toid[tags[i]]
			score = 0.0
			if estimatetype == SX:
				score += outside[lhs, left, right, 0]
				if score > 300.0: continue
			elif estimatetype == SXlrgaps:
				score += outside[lhs, length, left+right, gaps]
				if score > 300.0: continue
			tagitem = new_FatChartItem(lhs)
			SETBIT(tagitem.vec, i)
			agenda[tagitem] = new_Edge(score, 0.0, 0.0, -1, item, FATNONE)
			chart[tagitem] = []
			recognized = True
		elif not recognized:
			return chart, FATNONE, "not covered: '%s'. " % (tags[i] if tags else w)

	# parsing
	while agenda.length:
		entry = agenda.popentry()
		item = <FatChartItem>entry.key
		edge = <LCFRSEdge>entry.value
		chart[item].append(iscore(edge))
		(<dict>viterbi[item.label])[item] = edge
		if item.label == goal.label and item.vec == goal.vec:
			if not exhaustive: break
		else:
			x = edge.inside

			# unary
			if estimates is not None:
				length = abitcount(item.vec, SLOTS)
				left = anextset(item.vec, 0, SLOTS)
				gaps = abitlength(item.vec, SLOTS) - length - left
				right = lensent - length - left - gaps
			for i in range(grammar.numrules):
				rule = grammar.unary[item.label][i]
				if rule.rhs1 != item.label: break
				score = inside = x + rule.prob
				if estimatetype == SX:
					score += outside[rule.lhs, left, right, 0]
					if score > 300.0: continue
				elif estimatetype == SXlrgaps:
					score += outside[rule.lhs, length, left+right, gaps]
					if score > 300.0: continue
				newitem.label = rule.lhs
				ulongcpy(newitem.vec, item.vec, SLOTS)
				newitem = process_fatedge(newitem, score, inside, rule.prob,
					rule.no, item, FATNONE, agenda, chart, viterbi, grammar,
					exhaustive, whitelist,
					splitprune and grammar.fanout[rule.lhs] != 1,
					markorigin, &blocked)

			# binary left
			for i in range(grammar.numrules):
				rule = grammar.lbinary[item.label][i]
				if rule.rhs1 != item.label: break
				for I, e in (<dict>viterbi[rule.rhs2]).iteritems():
					sibling = <FatChartItem>I
					if fatconcat(rule, item.vec, sibling.vec):
						newitem.label = rule.lhs
						setunion(newitem.vec, item.vec, sibling.vec, SLOTS)
						y = (<LCFRSEdge>e).inside
						score = inside = x + y + rule.prob
						if estimatetype == SX:
							length = abitcount(newitem.vec, SLOTS)
							left = anextset(newitem.vec, 0, SLOTS)
							right = lensent - length - left
							score += outside[rule.lhs, left, right, 0]
							if score > 300.0: continue
						elif estimatetype == SXlrgaps:
							length = abitcount(newitem.vec, SLOTS)
							left = anextset(newitem.vec, 0, SLOTS)
							gaps = abitlength(newitem.vec, SLOTS) - length - left
							right = lensent - length - left - gaps
							score += outside[rule.lhs, length, left+right, gaps]
							if score > 300.0: continue
						newitem = process_fatedge(newitem, score, inside,
								rule.prob, rule.no, item, sibling, agenda, chart,
								viterbi, grammar, exhaustive, whitelist,
								splitprune and grammar.fanout[rule.lhs] != 1,
								markorigin, &blocked)

			# binary right
			for i in range(grammar.numrules):
				rule = grammar.rbinary[item.label][i]
				if rule.rhs2 != item.label: break
				for I, e in (<dict>viterbi[rule.rhs1]).iteritems():
					sibling = <FatChartItem>I
					if fatconcat(rule, sibling.vec, item.vec):
						newitem.label = rule.lhs
						setunion(newitem.vec, sibling.vec, item.vec, SLOTS)
						y = (<LCFRSEdge>e).inside
						score = inside = x + y + rule.prob
						if estimatetype == SX:
							length = abitcount(item.vec, SLOTS)
							left = anextset(item.vec, 0, SLOTS)
							right = lensent - length - left
							score += outside[rule.lhs, left, right, 0]
							if score > 300.0: continue
						elif estimatetype == SXlrgaps:
							length = abitcount(item.vec, SLOTS)
							left = anextset(item.vec, 0, SLOTS)
							gaps = abitlength(item.vec, SLOTS) - length - left
							right = lensent - length - left - gaps
							score += outside[rule.lhs, length, left+right, gaps]
							if score > 300.0: continue
						newitem = process_fatedge(newitem, score, inside,
								rule.prob, rule.no, sibling, item, agenda, chart,
								viterbi, grammar, exhaustive, whitelist,
								splitprune and grammar.fanout[rule.lhs] != 1,
								markorigin, &blocked)

		if agenda.length > maxA: maxA = agenda.length
	msg = ("agenda max %d, now %d, items %d (%d labels), edges %d, blocked %d"
		% (maxA, len(agenda), len(filter(None, chart.values())),
		len(filter(None, viterbi)), sum(map(len, chart.values())), blocked))
	if goal in chart: return chart, goal, msg
	else: return chart, FATNONE, "no parse " + msg

cdef FatChartItem fatcomponent = new_FatChartItem(0)
cdef inline FatChartItem process_fatedge(FatChartItem newitem, double score,
		double inside, double prob, int ruleno, FatChartItem left,
		FatChartItem right, EdgeAgenda agenda, dict chart, list viterbi,
		Grammar grammar, bint exhaustive, list whitelist, bint splitprune,
		bint markorigin, UInt *blocked):
	""" Decide what to do with a newly derived edge. """
	cdef UInt a, b, cnt, i
	cdef bint inagenda
	cdef bint inchart
	cdef list componentlist
	cdef dict componentdict
	# if item ends up in chart, newitem will be replaced
	# by a fresh object, otherwise, it can be re-used.
	inagenda = agenda.contains(newitem)
	inchart = PyDict_Contains(chart, newitem) == 1
	if not inagenda and not inchart:
		#if score > 300.0:
		#	blocked[0] += 1
		#	return newitem
		# check if we need to prune this item
		if whitelist is not None and whitelist[newitem.label] is not None:
			# disc. item to be treated as several split items?
			if splitprune:
				if markorigin: componentlist = <list>(whitelist[newitem.label])
				else: componentdict = <dict>(whitelist[newitem.label])
				b = cnt = 0
				a = anextset(newitem.vec, b, SLOTS)
				while a != -1:
					b = anextunset(newitem.vec, a, SLOTS)
					#given a=3, b=6, make bitvector: 1000000 - 1000 = 111000
					for i in range(a, b): SETBIT(fatcomponent.vec, i)
					if markorigin: componentdict = <dict>(componentlist[cnt])
					if PyDict_Contains(componentdict, fatcomponent) != 1:
						blocked[0] += 1
						return newitem
					a = anextset(newitem.vec, b, SLOTS)
					cnt += 1
			else:
				label = newitem.label; newitem.label = 0
				if PyDict_Contains(whitelist[label], newitem) != 1:
					#or inside+<double><object>outside > 300.0):
					blocked[0] += 1
					return newitem
				newitem.label = label

		# haven't seen this item before, won't prune, add to agenda
		agenda.setitem(newitem,
				new_Edge(score, inside, prob, ruleno, left, right))
		chart[newitem] = []
	# in agenda (maybe in chart)
	elif not exhaustive and inagenda:
		agenda.setifbetter(newitem,
				new_Edge(score, inside, prob, ruleno, left, right))
	elif (inagenda and inside < (<LCFRSEdge>(agenda.getitem(newitem))).inside):
		# item has lower score, decrease-key in agenda
		# (add old, suboptimal edge to chart if parsing exhaustively)
		chart[newitem].append(iscore(agenda.replace(newitem,
				new_Edge(score, inside, prob, ruleno, left, right))))
	# not in agenda => must be in chart
	elif (not inagenda and inside <
				(<LCFRSEdge>(<dict>viterbi[newitem.label])[newitem]).inside):
		#re-add to agenda because we found a better score.
		#should not happen without estimates!
		agenda.setitem(newitem,
				new_Edge(score, inside, prob, ruleno, left, right))
		logging.warning("WARN: updating score in agenda: %r", newitem)
	elif exhaustive:
		# suboptimal edge
		chart[newitem].append(iscore(
				new_Edge(score, inside, prob, ruleno, left, right)))
	return FatChartItem.__new__(FatChartItem)

cdef inline bint fatconcat(Rule rule, ULong *lvec, ULong *rvec):
	""" Determine the compatibility of two bitvectors (tuples of spans /
	ranges) according to the given yield function. Ranges should be
	non-overlapping, continuous when they are concatenated, and adhere to the
	ordering in the yield function.
	The yield function is a tuple of tuples with indices indicating from which
	vector the next span should be taken from, with 0 meaning left and 1 right.
	Note that the least significant bit is the lowest index in the vectors,
	which is the opposite of their normal presentation: 0b100 is the last
	terminal in a three word sentence, 0b001 is the first. E.g.,

	>>> lvec = 0b0011; rvec = 0b1000; yieldfunction = ((0,), (1,))
	>>> concat(((0,), (1,)), lvec, rvec)
	True		#discontinuous, non-overlapping, linearly ordered.
	>>> concat(((0, 1),), lvec, rvec)
	False		#lvec and rvec are not contiguous
	>>> concat(((1,), (0,)), lvec, rvec)
	False		#rvec's span should come after lvec's span

	update: yield functions are now encoded in a binary format; cf. containers.pyx
		( (0, 1, 0), (1, 0) ) ==> args: 0b10010     lengths: 0b00101
		NB: note reversal due to the way binary numbers are represented
		the least significant bit (rightmost) corresponds to the lowest
		index in the sentence / constituent (leftmost).
	"""
	cdef int lpos
	cdef int rpos
	cdef UInt n
	for n in range(SLOTS):
		if lvec[n] & rvec[n]: return False
	lpos = anextset(lvec, 0, SLOTS)
	rpos = anextset(rvec, 0, SLOTS)

	# if the yield function is the concatenation of two elements, and there are
	# no gaps in lvec and rvec, then this should^Wcould be quicker
	if 0b10 == rule.args == rule.lengths:
		n = anextunset(lvec, lpos, SLOTS)
		#e.g. lvec=0011 rvec=1100
		return rpos == n and -1 == anextset(lvec, n, SLOTS) == anextset(
			rvec, anextunset(rvec, rpos, SLOTS), SLOTS)

	#this algorithm was adapted from rparse, FastYFComposer.
	for n in range(bitlength(rule.lengths)):
		if testbitint(rule.args, n):
			# check if there are any bits left, and
			# if any bits on the right should have gone before
			# ones on this side
			if rpos == -1 or (lpos != -1 and lpos <= rpos):
				return False
			# jump to next gap
			rpos = anextunset(rvec, rpos, SLOTS)
			if lpos != -1 and lpos < rpos:
				return False
			# there should be a gap if and only if
			# this is the last element of this argument
			if testbitint(rule.lengths, n):
				if TESTBIT(lvec, rpos):
					return False
			elif not TESTBIT(lvec, rpos):
				return False
			# jump to next argument
			rpos = anextset(rvec, rpos, SLOTS)
		else: #if bit == 0:
			# vice versa to the above
			if lpos == -1 or (rpos != -1 and rpos <= lpos):
				return False
			lpos = anextunset(lvec, lpos, SLOTS)
			if rpos != -1 and rpos < lpos:
				return False
			if testbitint(rule.lengths, n):
				if TESTBIT(rvec, lpos):
					return False
			elif not TESTBIT(rvec, lpos):
				return False
			lpos = anextset(lvec, lpos, SLOTS)
	# success if we've reached the end of both left and right vector
	return lpos == rpos == -1

cdef CFGChartItem CFGNONE = new_CFGChartItem(0, 0, 0)
def cfgparse(list sent, Grammar grammar, start=1, tags=None):
	""" A CKY parser modeled after Bodenstab's `fast grammar loop.'
		and the Stanford parser. """
	cdef short left, right, mid, span, lensent = len(sent)
	cdef short narrowr, narrowl, widel, wider, minmid, maxmid
	cdef long numsymbols = len(grammar.toid)
	cdef double oldscore, prob
	cdef size_t i
	cdef UInt lhs, rhs1, Epsilon = grammar.toid["Epsilon"]
	cdef ULLong vec = 0
	cdef bint foundbetter = False
	cdef Rule *rule
	cdef CFGEdge edge
	cdef Entry entry
	cdef LexicalRule terminal
	cdef CFGChartItem item, goal = new_CFGChartItem(start, 0, len(sent))
	cdef Agenda unaryagenda = Agenda()
	cdef list chart = [[{} for _ in range(lensent+1)] for _ in range(lensent)]
	cdef list cell
	# the viterbi chart is initially filled with infinite log probabilities,
	# cells which are to be blocked contain NaN.
	cdef np.ndarray[np.double_t, ndim=3] viterbi = np.empty(
		(numsymbols, lensent, lensent+1), dtype='d')
	# matrices for the filter which gives minima and maxima for splits
	cdef np.ndarray[np.int16_t, ndim=2] minsplitleft, maxsplitleft, \
			minsplitright, maxsplitright
	minsplitleft = np.empty((numsymbols, lensent + 1), dtype='int16')
	minsplitleft.fill(-1); viterbi.fill(np.inf)
	maxsplitleft = np.empty_like(minsplitleft); maxsplitleft.fill(lensent+1)
	minsplitright = np.empty_like(minsplitleft); minsplitright.fill(lensent+1)
	maxsplitright = np.empty_like(minsplitleft); maxsplitright.fill(-1)

	# assign POS tags
	#print 1, # == span
	for i, w in enumerate(sent):
		left = i; right = i + 1
		recognized = False
		for terminal in grammar.lexical.get(w, []):
			# if we are given gold tags, make sure we only allow matching
			# tags - after removing addresses introduced by the DOP reduction
			if (not tags or grammar.tolabel[terminal.lhs] == tags[i]
				or grammar.tolabel[terminal.lhs].startswith(tags[i] + '@')):
				x = viterbi[terminal.lhs, left, right] = terminal.prob
				chart[left][right][terminal.lhs] = [new_CFGEdge(x, NULL, right)]
				# update filter
				if left > minsplitleft[terminal.lhs, right]:
					minsplitleft[terminal.lhs, right] = left
				if left < maxsplitleft[terminal.lhs, right]:
					maxsplitleft[terminal.lhs, right] = left
				if right < minsplitright[terminal.lhs, left]:
					minsplitright[terminal.lhs, left] = right
				if right > maxsplitright[terminal.lhs, left]:
					maxsplitright[terminal.lhs, left] = right
				recognized = True
		if not recognized and tags and tags[i] in grammar.toid:
			lhs = grammar.toid[tags[i]]
			viterbi[lhs, left, right] = 0.0
			chart[left][right][lhs] = [new_CFGEdge(0.0, NULL, right)]
			# update filter
			if left > minsplitleft[lhs, right]:
				minsplitleft[lhs, right] = left
			if left < maxsplitleft[lhs, right]:
				maxsplitleft[lhs, right] = left
			if right < minsplitright[lhs, left]:
				minsplitright[lhs, left] = right
			if right > maxsplitright[lhs, left]:
				maxsplitright[lhs, left] = right
			recognized = True
		elif not recognized:
			logging.error("not covered: '%s'. ", tags[i] if tags else w)
			return chart, CFGNONE

		# unary rules on the span of this POS tag
		# NB: for this agenda, only the probabilities of the edges matter
		unaryagenda.update([(
			rhs1, new_CFGEdge(viterbi[rhs1, left, right], NULL, 0))
			for rhs1 in range(grammar.nonterminals)
			if isfinite(viterbi[rhs1, left, right])
			and grammar.unary[rhs1].rhs1 == rhs1])
		while unaryagenda.length:
			rhs1 = unaryagenda.popentry().key
			for i in range(grammar.numrules):
				rule = &(grammar.unary[rhs1][i])
				if rule.rhs1 != rhs1: break
				prob = rule.prob + viterbi[rhs1, left, right]
				if isfinite(viterbi[rule.lhs, left, right]):
					cell = chart[left][right][rule.lhs]
				else:
					cell = chart[left][right][rule.lhs] = []
				edge = new_CFGEdge(prob, rule, right)
				cell.append(edge)
				if prob < viterbi[rule.lhs, left, right]:
					unaryagenda.setifbetter(rule.lhs, edge)
					viterbi[rule.lhs, left, right] = prob
					# update filter
					if left > minsplitleft[rule.lhs, right]:
						minsplitleft[rule.lhs, right] = left
					if left < maxsplitleft[rule.lhs, right]:
						maxsplitleft[rule.lhs, right] = left
					if right < minsplitright[rule.lhs, left]:
						minsplitright[rule.lhs, left] = right
					if right > maxsplitright[rule.lhs, left]:
						maxsplitright[rule.lhs, left] = right

	for span in range(2, lensent + 1):
		# print span,
		#sys.stdout.flush()

		# constituents from left to right
		for left in range(0, lensent - span + 1):
			right = left + span
			# binary rules
			for i in range(grammar.numrules):
				rule = &(grammar.bylhs[0][i])
				if rule.lhs == grammar.nonterminals: break
				elif not rule.rhs2: continue
				#if not (np.isfinite(viterbi[rule.rhs1,left,left+1:right]).any()
				#and np.isfinite(viterbi[rule.rhs2,left:right-1,right]).any()):
				#	continue

				narrowr = minsplitright[rule.rhs1, left]
				if narrowr >= right: continue
				narrowl = minsplitleft[rule.rhs2, right]
				if narrowl < narrowr: continue
				widel = maxsplitleft[rule.rhs2, right]
				minmid = narrowr if narrowr > widel else widel
				wider = maxsplitright[rule.rhs1, left]
				maxmid = 1 + (wider if wider < narrowl else narrowl)
				oldscore = viterbi[rule.lhs, left, right]
				foundbetter = False
				for mid in range(minmid, maxmid):
					if (isfinite(viterbi[rule.rhs1, left, mid])
						and isfinite(viterbi[rule.rhs2, mid, right])):
						prob = (rule.prob + viterbi[rule.rhs1, left, mid]
								+ viterbi[rule.rhs2, mid, right])
						if isfinite(viterbi[rule.lhs, left, right]):
							cell = chart[left][right][rule.lhs]
						else:
							cell = chart[left][right][rule.lhs] = []
						cell.append(new_CFGEdge(prob, rule, mid))
						if prob < viterbi[rule.lhs, left, right]:
							foundbetter = True
							viterbi[rule.lhs, left, right] = prob
				# update filter
				if foundbetter and isinf(oldscore):
					if left > minsplitleft[rule.lhs, right]:
						minsplitleft[rule.lhs, right] = left
					if left < maxsplitleft[rule.lhs, right]:
						maxsplitleft[rule.lhs, right] = left
					if right < minsplitright[rule.lhs, left]:
						minsplitright[rule.lhs, left] = right
					if right > maxsplitright[rule.lhs, left]:
						maxsplitright[rule.lhs, left] = right

			# unary rules on this span
			unaryagenda.update([(rhs1,
				new_CFGEdge(viterbi[rhs1, left, right], NULL, 0))
				for rhs1 in range(grammar.nonterminals)
				if isfinite(viterbi[rhs1, left, right])
				and grammar.unary[rhs1].rhs1 == rhs1])
			while unaryagenda.length:
				rhs1 = unaryagenda.popentry().key
				for i in range(grammar.numrules):
					rule = &(grammar.unary[rhs1][i])
					if rule.rhs1 != rhs1: break
					prob = rule.prob + viterbi[rhs1, left, right]
					if isfinite(viterbi[rule.lhs, left, right]):
						cell = chart[left][right][rule.lhs]
					else:
						cell = chart[left][right][rule.lhs] = []
					edge = new_CFGEdge(prob, rule, right)
					cell.append(edge)
					if prob < viterbi[rule.lhs, left, right]:
						viterbi[rule.lhs, left, right] = prob
						unaryagenda.setifbetter(rule.lhs, edge)
						# update filter
						if left > minsplitleft[rule.lhs, right]:
							minsplitleft[rule.lhs, right] = left
						if left < maxsplitleft[rule.lhs, right]:
							maxsplitleft[rule.lhs, right] = left
						if right < minsplitright[rule.lhs, left]:
							minsplitright[rule.lhs, left] = right
						if right > maxsplitright[rule.lhs, left]:
							maxsplitright[rule.lhs, left] = right
	# print
	if goal.label in chart[0][lensent]: return chart, goal
	else: return chart, CFGNONE

cdef inline LCFRSEdge iscore(LCFRSEdge e):
	""" Replace estimate with inside probability """
	e.score = e.inside
	return e

def binrepr(ChartItem a, n, cfg=False):
	if cfg:
		start = nextset((<SmallChartItem>a).vec, 0)
		return "%d-%d" % (start, nextunset((<SmallChartItem>a).vec, start))
	if isinstance(a, SmallChartItem):
		vec = (<SmallChartItem>a).vec
		result = bin(vec)[2:]
	else: result = binrepr1((<FatChartItem>a).vec)
	return result.rjust(n, "0")[::-1]

def sortfunc(a):
	if isinstance(a, SmallChartItem):
		return (bitcount((<SmallChartItem>a).vec), (<SmallChartItem>a).vec)
	elif isinstance(a, FatChartItem):
		return (abitcount((<FatChartItem>a).vec, SLOTS),
			anextset((<FatChartItem>a).vec, 0, SLOTS))
	elif isinstance(a, Edge):
		return (<Edge>a).inside

def pprint_chart(chart, sent, tolabel, cfg=False):
	""" `pretty print' a chart. """
	if isinstance(chart, list):
		pprint_chart_cfg(chart, sent, tolabel)
	else:
		pprint_chart_lcfrs(chart, sent, tolabel, cfg=cfg)

def pprint_chart_lcfrs(chart, sent, tolabel, cfg=False):
	cdef ChartItem a
	cdef LCFRSEdge edge
	print "chart:"
	for a in sorted(chart, key=sortfunc):
		if chart[a] == []: continue
		print "%s[%s] =>" % (tolabel[a.label], binrepr(a, len(sent), cfg))
		if isinstance(chart[a], float): continue
		for edge in sorted(chart[a], key=sortfunc):
			print "%g\t%g" % (exp(-edge.inside), exp(-edge.prob)),
			if edge.left.label:
				print "\t%s[%s]" % (tolabel[edge.left.label],
						binrepr(edge.left, len(sent), cfg)),
			else:
				if isinstance(edge.left, SmallChartItem):
					print "\t", repr(sent[(<SmallChartItem>edge.left).vec]),
				else: print "\t", repr(sent[(<FatChartItem>edge.left).vec[0]]),
			if edge.right:
				print "\t%s[%s]" % (tolabel[edge.right.label],
						binrepr(edge.right, len(sent), cfg)),
			print
		print

def pprint_chart_cfg(chart, sent, tolabel, cfg=True):
	cdef CFGEdge edge
	print "chart:"
	for left, _ in enumerate(chart):
		for right, _ in enumerate(chart[left]):
			for label in chart[left][right]:
				if chart[left][right][label] == []: continue
				print "%s[%d:%d] =>" % (tolabel[label], left, right)
				#?? if isinstance(chart[left][right][label], float): continue
				for edge in sorted(chart[left][right][label], key=sortfunc):
					if edge.rule is NULL:
						print "%g\t??" % (exp(-edge.inside)),
						print "\t", repr(sent[edge.mid-1]),
					else:
						print "%g\t%g" % (exp(-edge.inside), exp(-edge.rule.prob)),
						print "\t%s[%d:%d]" % (tolabel[edge.rule.rhs1],
								left, edge.mid),
						if edge.rule.rhs2:
							print "\t%s[%d:%d]" % (tolabel[edge.rule.rhs2],
								edge.mid, right),
					print
				print

def do(sent, grammar):
	from disambiguation import marginalize
	from operator import itemgetter
	print "sentence", sent
	chart, start, _ = parse(sent.split(), grammar, start=grammar.toid['S'])
	if len(sent) < sizeof(ULLong):
		pprint_chart(chart, sent.split(), grammar.tolabel)
	if not start:
		print "no parse"
		return False
	else:
		print "10 best parse trees:"
		mpp, _ = marginalize(chart, start, grammar.tolabel)
		for a, p in reversed(sorted(mpp.items(), key=itemgetter(1))): print p,a
		print
		return True

def main():
	from containers import Grammar
	cdef Rule rule
	rule.args = 0b1010; rule.lengths = 0b1010
	assert concat(rule, 0b100010, 0b1000100)
	assert not concat(rule, 0b1010, 0b10100)
	rule.args = 0b101; rule.lengths = 0b101
	assert concat(rule, 0b10000, 0b100100)
	assert not concat(rule, 0b1000, 0b10100)
	grammar = Grammar([
		((('S','VP2','VMFIN'), ((0,1,0),)), 0.0),
		((('VP2','VP2','VAINF'),  ((0,),(0,1))), log(0.5)),
		((('VP2','PROAV','VVPP'), ((0,),(1,))), log(0.5)),
		((('PROAV', 'Epsilon'), ('Daruber',)), 0.0),
		((('VAINF', 'Epsilon'), ('werden',)), 0.0),
		((('VMFIN', 'Epsilon'), ('muss',)), 0.0),
		((('VVPP', 'Epsilon'), ('nachgedacht',)), 0.0)])
	print grammar
	print "Rule structs take", sizeof(Rule), "bytes"

	lng = 67
	assert do("Daruber muss nachgedacht werden", grammar)
	assert do("Daruber muss nachgedacht werden werden", grammar)
	assert do("Daruber muss nachgedacht werden werden werden", grammar)
	print "ungrammatical sentence:"
	assert not do("muss Daruber nachgedacht werden", grammar)	#no parse
	print "(as expected)"
	print "long sentence (%d words):" % lng
	assert do("Daruber muss nachgedacht %s" % " ".join(
		(lng-3)*["werden"]), grammar)

	cfg = Grammar([
		((('S', 'D'), ((0,),)), log(0.5)),
		((('S', 'A'), ((0,),)), log(0.8)),
		((('A', 'A'), ((0,),)), log(0.7)),
		((('A', 'B'), ((0,),)), log(0.6)),
		((('A', 'C'), ((0,),)), log(0.5)),
		((('A', 'D'), ((0,),)), log(0.4)),
		((('B', 'A'), ((0,),)), log(0.3)),
		((('B', 'B'), ((0,),)), log(0.2)),
		((('B', 'C'), ((0,),)), log(0.1)),
		((('B', 'D'), ((0,),)), log(0.2)),
		((('B', 'C'), ((0,),)), log(0.3)),
		((('C', 'A'), ((0,),)), log(0.4)),
		((('C', 'B'), ((0,),)), log(0.5)),
		((('C', 'C'), ((0,),)), log(0.6)),
		((('C', 'D'), ((0,),)), log(0.7)),
		((('D', 'A'), ((0,),)), log(0.8)),
		((('D', 'B'), ((0,),)), log(0.9)),
		((('D', 'C'), ((0,),)), log(0.8)),
		((('D', 'NP', 'VP'), ((0,1),)), 0.0),
		((('NP', 'Epsilon'), ('mary',)), 0.0),
		((('VP', 'Epsilon'), ('walks',)), 0.0)])
	cfg.getunaryclosure()
	print cfg
	print "cfg parsing; sentence: mary walks"
	print "lcfrs",
	chart1, start, _ = parse("mary walks".split(), cfg, start=cfg.toid['S'],
		exhaustive=True)
	pprint_chart(chart1, "mary walks".split(), cfg.tolabel)

	print "pcfg",
	chart, start = cfgparse("mary walks".split(), cfg, start=cfg.toid['S'])
	pprint_chart(chart, "mary walks".split(), cfg.tolabel)
	assert start
	#assert chart.viewkeys() == chart1.viewkeys(), (
	#	chart.viewkeys() ^ chart1.viewkeys())
	#assert all(sorted(chart1[a]) == sorted(chart[a]) for a in chart), (
	#	[(a,b, chart1[a]) for a,b in chart.items() if chart1[a] != b])

if __name__ == '__main__': main()