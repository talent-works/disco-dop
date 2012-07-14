""" Fast Fragment Seeker
Extracts recurring fragments from constituency treebanks.

NB: there is a known bug in multiprocessing which makes it impossible to detect
ctrl-c or fatal errors like segmentation faults in children which causes the
master program to wait forever for output from its children. Therefore if
you want to abort, kill the program manually (e.g., press ctrl-z and run
'kill %1'). If the program seems stuck, re-run without multiprocessing
(pass --numproc 1) to see if there might be a bug. """

import os, sys, codecs, logging
from multiprocessing import Pool, cpu_count, log_to_stderr, SUBDEBUG
from collections import defaultdict
from itertools import count
from getopt import gnu_getopt, GetoptError
from _fragments import extractfragments, fastextractfragments, exactcounts, \
		exactindices, completebitsets, readtreebank, indextrees, getctrees

# this fixes utf-8 output when piped through e.g. less
# won't help if the locale is not actually utf-8, of course
sys.stdout = codecs.getwriter('utf8')(sys.stdout)
params = {}

def usage():
	print """Fast Fragment Seeker
usage: %s [options] treebank1 [treebank2]
If only one treebank is given, fragments occurring at least twice are sought.
If two treebanks are given, finds common fragments between first & second.
Input is in Penn treebank format (S-expressions), one tree per line.
Output contains lines of the form "tree<TAB>frequency".
Frequencies always refer to the first treebank.
Output is sent to stdout; to save the results, redirect to a file.
--complete    find complete matches of fragments from treebank2 in treebank1.
--exact       find exact frequencies
--indices     report sets of indices instead of frequencies.
--disc        work with discontinuous trees; input is in Negra export format.
              output: tree<TAB>sentence<TAB>frequency
              where "tree' has indices as leaves, referring to elements of
              "sentence", a space separated list of words.
--numproc n   use n independent processes, to enable multi-core usage.
              The default is not to use multiprocessing; use 0 to use all CPUs.
--encoding x  use x as treebank encoding, e.g. UTF-8, ISO-8859-1, etc.
--numtrees n  only read first n trees from treebank
--batch dir   enable batch mode; any number of treebanks > 1 can be given;
              first treebank will be compared to all others.
              results are written to filenames of the form dir/A_B.
--quadratic   use the slower, quadratic algorithm for finding fragments.
--nofreq      do not report frequencies.
--debug       extra debug information, ignored when numproc > 1.
--quiet       disable all messages.""" % sys.argv[0]


def readtreebanks(treebank1, treebank2=None, discontinuous=False,
	limit=0, encoding="utf-8"):
	labels = {}
	prods = {}
	trees1, sents1 = readtreebank(treebank1, labels, prods,
		not params['quadratic'], discontinuous, limit, encoding)
	trees2, sents2 = readtreebank(treebank2, labels, prods,
		not params['quadratic'], discontinuous, limit, encoding)
	revlabel = sorted(labels, key=labels.get)
	treeswithprod = indextrees(trees1, prods)
	return dict(trees1=trees1, sents1=sents1, trees2=trees2, sents2=sents2,
		labels=labels, prods=prods, revlabel=revlabel,
		treeswithprod=treeswithprod)

def read2ndtreebank(treebank2, labels, prods, discontinuous=False,
	limit=0, encoding="utf-8"):
	trees2, sents2 = readtreebank(treebank2, labels, prods,
		not params['quadratic'], discontinuous, limit, encoding)
	revlabel = sorted(labels, key=labels.get)
	return dict(trees2=trees2, sents2=sents2, labels=labels, prods=prods,
		revlabel=revlabel)

def initworker(treebank1, treebank2, limit, encoding):
	global params
	params.update(readtreebanks(treebank1, treebank2,
		limit=limit, discontinuous=params['disc'], encoding=encoding))
	trees1 = params['trees1']
	assert trees1
	m = "treebank1: %d trees; %d nodes (max: %d);" % (
		len(trees1), trees1.nodes, trees1.maxnodes)
	if treebank2:
		trees2 = params['trees2']
		assert trees2
		m += " treebank2: %d trees; %d nodes (max %d);" % (
			len(trees2), trees2.nodes, trees2.maxnodes)
	logging.info("%s labels: %d, prods: %d" % (m, len(params['labels']),
		len(params['prods'])))

def worker(offset):
	trees1 = params['trees1']; sents1 = params['sents1']
	trees2 = params['trees2']; sents2 = params['sents2']
	labels = params['labels']; prods = params['prods']
	assert offset < len(trees1)
	end = min(offset + params['chunk'], len(trees1))
	result = {}
	try:
		if params['quadratic']:
			result = extractfragments(trees1, sents1, offset, end, labels,
				prods, params['revlabel'], trees2, sents2,
				approx=not (params['exact'] or params['indices']),
				discontinuous=params['disc'], debug=False)
		else:
			result = fastextractfragments(trees1, sents1, offset, end, labels,
				prods, params['revlabel'], trees2, sents2,
				approx=not (params['exact'] or params['indices']),
				discontinuous=params['disc'], debug=False)
	except Exception as e: logging.error(e)
	logging.info("finished %d--%d" % (offset, end))
	return result

def exactcountworker((n, m, fragments)):
	trees1 = params['trees1']; sents1 = params['sents1']
	if params['indices']:
		results = exactindices(trees1, trees1, fragments, params['disc'],
				params['revlabel'], params['treeswithprod'],
				fast=not params['quadratic'])
		logging.info("exact indices %d of %d" % (n+1, m))
	elif params['complete']:
		results = exactcounts(trees1, params['trees2'], fragments,
				params['disc'], params['revlabel'], params['treeswithprod'],
				fast=not params['quadratic'])
		logging.info("complete fragments %d of %d" % (n+1, m))
	else:
		results = exactcounts(trees1, trees1, fragments, params['disc'],
				params['revlabel'], params['treeswithprod'],
				fast=not params['quadratic'])
		logging.info("exact counts %d of %d" % (n+1, m))
	return results

def main(argv):
	global params
	flags = ("exact", "indices", "nofreq", "complete",
			"disc", "quiet", "debug", "quadratic")
	options = ("numproc=", "numtrees=", "encoding=", "batch=")
	try: opts, args = gnu_getopt(argv[1:], "", flags + options)
	except GetoptError, err:
		print err
		usage()
		exit(2)
	else: opts = dict(opts)

	for flag in flags: params[flag] = "--" + flag in opts
	numproc = int(opts.get("--numproc", 1))
	if numproc == 0: numproc = cpu_count()
	numtrees = int(opts.get("--numtrees", 0))
	encoding = opts.get("--encoding", "UTF-8")
	batch = opts.get("--batch")

	if len(args) < 1: print "missing treebank argument"
	if batch is None and len(args) not in (1, 2):
		print "incorrect number of arguments:", args
		usage()
		exit(2)
	if batch:
		assert numproc == 1, "batch mode only supported in single-process mode"
	if args[0] == "-": args[0] = "/dev/stdin"
	for a in args: assert os.path.exists(a), "not found: %s" % a
	if params['complete']: assert len(args) == 2 or batch, (
		"need at least two treebanks with --complete.")
	level = logging.WARNING if params['quiet'] else logging.INFO
	logging.basicConfig(level=level, format='%(message)s')

	if params['debug'] and numproc > 1:
		logger = log_to_stderr()
		logger.setLevel(SUBDEBUG)

	logging.info("Fast Fragment Seeker")

	assert numproc
	limit = numtrees
	if numtrees == 0:
		if params['disc']: numtrees = open(args[0]).read().count("#BOS")
		else: numtrees = sum(1 for _ in open(args[0]))
	assert numtrees
	mult = 3 #max(1, int(log(numtrees, 10)))
	chunk = numtrees / (mult*numproc)
	if numtrees % (mult*numproc): chunk += 1
	numchunks = numtrees / chunk + (1 if numtrees % chunk else 0)
	if params['exact'] or params['indices']: fragments = {}
	else: fragments = defaultdict(int)
	params['chunk'] = chunk
	logging.info("parameters:\n%s" % "\n".join("    %s: %r" % kv
		for kv in sorted(params.items())))
	logging.info("\n".join("treebank%d: %s" % (n + 1, a)
		for n, a in enumerate(args)))

	if numproc == 1 and batch:
		initworker(args[0], None, limit, encoding)
		trees1 = params['trees1']; sents1 = params['sents1']
		if params['complete']:
			raise NotImplemented
		for a in args[1:]:
			params.update(read2ndtreebank(a, params['labels'], params['prods'],
				params['disc'], limit, encoding))
			trees2 = params['trees2']; sents2 = params['sents2']
			labels = params['labels']; prods = params['prods']
			if params['quadratic']:
				fragments = extractfragments(trees1, sents1, 0, 0, labels,
					prods, params['revlabel'], trees2, sents2,
					discontinuous=params['disc'], debug=params['debug'],
					approx=not (params['exact'] or params['indices']))
			else:
				fragments = fastextractfragments(trees1, sents1, 0, 0, labels,
					prods, params['revlabel'], trees2, sents2,
					discontinuous=params['disc'], debug=params['debug'],
					approx=not (params['exact'] or params['indices']))
			if params['indices']:
				logging.info("getting indices of occurrence")
				keys, f = zip(*fragments.items())
				counts = exactindices(trees1, trees1, f,
						params['disc'], params['revlabel'],
						params['treeswithprod'], fast=not params['quadratic'])
				fragments = zip(keys, counts)
			elif params['exact']:
				logging.info("getting exact counts")
				keys, f = zip(*fragments.items())
				counts = exactcounts(trees1, trees1, f,
						params['disc'], params['revlabel'],
						params['treeswithprod'], fast=not params['quadratic'])
				fragments = zip(keys, counts)
			filename="%s/%s_%s" % (batch, os.path.basename(args[0]),
				os.path.basename(a))
			out = codecs.open(filename, "w", encoding=encoding)
			printfragments(fragments, out=out)
			logging.info("wrote to %s" % filename)
		return
	elif numproc == 1:
		initworker(args[0], args[1] if len(args) == 2 else None,
			limit, encoding)
		trees1 = params['trees1']; sents1 = params['sents1']
		trees2 = params['trees2']; sents2 = params['sents2']
		labels = params['labels']; prods = params['prods']
		if params['complete']:
			#					        needle
			fragments = completebitsets(trees2, sents2, params['revlabel'],
					params['disc'])
		elif params['quadratic']:
			fragments = extractfragments(trees1, sents1, 0, 0, labels, prods,
				params['revlabel'], trees2, sents2,
				approx=not (params['exact'] or params['indices']),
				discontinuous=params['disc'], debug=params['debug'])
		else:
			fragments = fastextractfragments(trees1, sents1, 0, 0, labels,
				prods, params['revlabel'], trees2, sents2,
				approx=not (params['exact'] or params['indices']),
				discontinuous=params['disc'], debug=params['debug'])
		if params['nofreq']:
			pass
		elif params['complete'] or params['indices'] or params['exact']:
			keys, f = zip(*fragments.items())
			if params['complete']:
				logging.info("getting exact counts")
				#					haystack,needle  needle
				counts = exactcounts(trees1, trees2, f,
					params['disc'], params['revlabel'], params['treeswithprod'],
					fast=not params['quadratic'])
			elif params['indices']:
				logging.info("getting indices of occurrence")
				counts = exactindices(trees1, trees1, f,
					params['disc'], params['revlabel'], params['treeswithprod'],
					fast=not params['quadratic'])
			elif params['exact']:
				logging.info("getting exact counts")
				counts = exactcounts(trees1, trees1, f,
					params['disc'], params['revlabel'], params['treeswithprod'],
					fast=not params['quadratic'])
			fragments = zip(keys, counts)
		else: fragments = fragments.items()
		printfragments(fragments)
		return

	# multiprocessing part
	# start worker processes
	pool = Pool(processes=numproc, initializer=initworker,
		initargs=(args[0], args[1] if len(args) == 2 else None,
			limit, encoding))
	# FIXME: detect corpus reading errors here (e.g. wrong encoding)

	if params['complete']:
		initworker(args[0], args[1] if len(args) == 2 else None,
			limit, encoding)
		fragments = completebitsets(params['trees2'], params['sents2'],
			params['revlabel'], params['disc'])
	else:
		logging.info("work division:\n%s" % "\n".join("    %s: %r" % kv
			for kv in sorted(dict(
			chunksize=chunk,numchunks=numchunks,mult=mult).items())))
		dowork = pool.imap_unordered(worker, range(0, numtrees, chunk))
		for n, a in enumerate(dowork):
			if params['exact'] or params['indices']: fragments.update(a)
			else:
				for frag, x in a.items(): fragments[frag] += x
	if params['exact'] or params['complete'] or params['indices']:
		task = "indices" if params['indices'] else "counts"
		logging.info("dividing work for exact %s" % task)
		countchunk = 20000
		keys, f = zip(*fragments.items())
		work = [f[n:n+countchunk] for n in range(0, len(f), countchunk)]
		work = [(n, len(work), a) for n, a in enumerate(work)]
		dowork = pool.imap(exactcountworker, work)
		logging.info("getting exact %s" % task)
		counts = []
		for a in dowork: counts.extend(a)
		fragments = zip(key, counts)
	else: fragments = fragments.items()
	pool.terminate()
	pool.join()
	del dowork, pool
	printfragments(fragments)

def printfragments(fragments, out=sys.stdout):
	logging.info("number of fragments: %d" % len(fragments))
	if params['nofreq']:
		for a, _ in fragments:
			out.write("%s\n" % (("%s\t%s" % (a[0],
					" ".join("%s" % x if x else "" for x in a[1])))
					if params['disc'] else a))
		return
	# when comparing two treebanks, a frequency of 1 is normal;
	# otherwise, raise alarm.
	if params.get('trees2'): threshold = 0
	else: threshold = 1
	if params['indices']:
		for a, theindices in fragments:
			if len(theindices) > threshold:
				out.write("%s\t%r\n" % ( ("%s\t%s" % (a[0],
					" ".join("%s" % x if x else "" for x in a[1])))
					if params['disc'] else a,
					list(sorted(theindices))))
			elif threshold:
				logging.warning("invalid fragment--frequency=1: %s" % a)
		return
	for a, freq in fragments:
		if freq > threshold:
			out.write("%s\t%d\n" % (("%s\t%s" % (a[0],
				" ".join("%s" % x if x else "" for x in a[1])))
				if params['disc'] else a, freq))
		elif threshold: logging.warning("invalid fragment--frequency=1: %s" % a)

def initworkersimple(trees, sents):
	global params
	params.update(getctrees(trees, sents))
	assert params['trees1']

def getfragments(trees, sents):
	""" Get recurring fragments with exact counts in a single treebank,
	using all available CPUs."""
	from treebank import export
	numproc = cpu_count()
	numtrees = len(trees)
	assert numtrees
	mult = 3
	chunk = numtrees / (mult*numproc)
	if numtrees % (mult*numproc): chunk += 1
	numchunks = numtrees / chunk + (1 if numtrees % chunk else 0)
	fragments = {}
	params.update(chunk=chunk, disc=True, exact=True,
		complete=False, indices=False, quadratic=False)
	# start worker processes
	pool = Pool(processes=numproc, initializer=initworkersimple,
		initargs=(trees, sents))

	logging.info("work division:\n%s" % "\n".join("    %s: %r" % kv
		for kv in sorted(dict(
		chunksize=chunk,numchunks=numchunks,mult=mult).items())))
	dowork = pool.imap_unordered(worker, range(0, numtrees, chunk))
	for n, a in enumerate(dowork):
		fragments.update(a)
	logging.info("dividing work for exact counts")
	countchunk = 20000
	keys, f = zip(*fragments.items())
	tmp = [f[n:n+countchunk] for n in range(0, len(f), countchunk)]
	work = [(n, len(tmp), a) for n, a in enumerate(tmp)]
	dowork = pool.imap(exactcountworker, work)
	logging.info("getting exact counts")
	counts = []
	for a in dowork: counts.extend(a)

	pool.terminate()
	pool.join()
	del dowork, pool
	logging.info("found %d fragments" % len(fragments))
	return dict(zip(keys, counts))

if __name__ == '__main__': main(sys.argv)