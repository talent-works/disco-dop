"""Web interface to the disco-dop parser.

Requires Flask. Expects a series of grammars produced by runexp in
subdirectories of ``grammar/``

Also usable from the command line:
$ curl http://localhost:5000/parser/parse -G --data-urlencode "sent=What's up?"
"""
from __future__ import absolute_import
import os
import re
import glob
import heapq
import string  # pylint: disable=W0402
import random
import logging
import math
from operator import itemgetter
from flask import Flask, Markup, Response, redirect, url_for
from flask import request, render_template, send_from_directory
from werkzeug.contrib.cache import SimpleCache
from werkzeug.urls import url_encode
from discodop import treebank
from discodop.tree import Tree, DrawTree, DrawDependencies, \
		writediscbrackettree
from discodop.parser import Parser, readparam, readgrammars, probstr

LIMIT = 40  # maximum sentence length
APP = Flask(__name__)
CACHE = SimpleCache()
PARSERS = {}
SHOWFUNC = True  # show function tags in results
SHOWMORPH = True  # show morphological features in results


@APP.route('/')
def main():
	"""Redirect to main page."""
	return redirect(url_for('index'))


@APP.route('/parser/')
def index():
	"""Serve the main form."""
	return render_template('parse.html', result=Markup(parse()), langs=PARSERS)


@APP.route('/parser/parse')
def parse():
	"""Parse sentence and return a textual representation of a parse tree.

	Output is either in a HTML fragment or in plain text. To be invoked by an
	AJAX call."""
	sent = request.args.get('sent', None)
	objfun = request.args.get('objfun', 'mpp')
	est = request.args.get('est', 'rfe')
	marg = request.args.get('marg', 'nbest')
	coarse = request.args.get('coarse', 'pcfg')
	html = 'html' in request.args
	lang = request.args.get('lang', 'detect')
	if not sent:
		return ''
	nbest = None
	senttok = tokenize(sent)
	if not senttok or not 1 <= len(senttok) <= LIMIT:
		return 'Sentence too long: %d words, max %d' % (len(senttok), LIMIT)
	if lang == 'detect':
		lang = guesslang(senttok)
	elif lang not in PARSERS:
		return 'unknown language %r; languages: %r' % (lang, PARSERS.keys())
	key = (senttok, est, marg, objfun, coarse, lang)
	resp = CACHE.get(key)
	if resp is None:
		link = 'parse?' + url_encode(dict(sent=sent, est=est, marg=marg,
				objfun=objfun, coarse=coarse, html=html))
		PARSERS[lang].stages[-1].estimator = est
		PARSERS[lang].stages[-1].objective = objfun
		PARSERS[lang].stages[-1].kbest = marg in ('nbest', 'both')
		PARSERS[lang].stages[-1].sample = marg in ('sample', 'both')
		if PARSERS[lang].stages[0].mode.startswith('pcfg') and coarse:
			PARSERS[lang].stages[0].mode = (
					'pcfg' if coarse == 'pcfg-posterior' else coarse)
			if len(PARSERS[lang].stages) > 1:
				PARSERS[lang].stages[1].k = (1e-5
						if coarse == 'pcfg-posterior' else 50)

		results = list(PARSERS[lang].parse(senttok))
		if results[-1].noparse:
			parsetrees = []
			result = 'no parse!'
			nbest = dep = depsvg = ''
		else:
			if SHOWMORPH:
				replacemorph(results[-1].parsetree)
			if SHOWFUNC:
				treebank.handlefunctions('add', results[-1].parsetree, pos=True)
			tree = str(results[-1].parsetree)
			prob = results[-1].prob
			parsetrees = results[-1].parsetrees or []
			parsetrees = heapq.nlargest(10, parsetrees, key=itemgetter(1))
			parsetrees_ = []
			APP.logger.info('[%s] %s', probstr(prob), tree)
			tree = Tree.parse(tree, parse_leaf=int)
			result = Markup(DrawTree(tree, senttok).text(
					unicodelines=True, html=html, funcsep='-'))
			for tree, prob, x in parsetrees:
				tree = PARSERS[lang].postprocess(tree, senttok, -1)[0]
				if SHOWMORPH:
					replacemorph(tree)
				if SHOWFUNC:
					treebank.handlefunctions('add', tree, pos=True)
				parsetrees_.append((tree, prob, x))
			if PARSERS[lang].headrules:
				xtree = PARSERS[lang].postprocess(
						parsetrees[0][0], senttok, -1)[0]
				dep = treebank.writedependencies(xtree, senttok, 'conll')
				depsvg = Markup(DrawDependencies.fromconll(dep).svg())
			else:
				dep = depsvg = ''
			rid = randid()
			nbest = Markup('\n\n'.join('%d. [%s] '
					'<a href=\'javascript: toggle("f%s%d"); \'>'
					'toggle fragments</a>\n'
					'<span id=f%s%d style="display: none; ">'
					'Fragments used in the highest ranked derivation'
					' of this parse tree:\n%s</span>\n%s' % (
						n + 1,
						probstr(prob),
						rid, n + 1,
						rid, n + 1,
						'\n\n'.join(
							DrawTree(frag).text(unicodelines=True, html=html)
							for frag in fragments or ()  # if frag.count('(') > 1
						),
						DrawTree(tree, senttok).text(
							unicodelines=True, html=html, funcsep='-'))
					for n, (tree, prob, fragments) in enumerate(parsetrees_)))
		msg = '\n'.join(stage.msg for stage in results)
		elapsed = [stage.elapsedtime for stage in results]
		elapsed = 'CPU time elapsed: %s => %gs' % (
				' '.join('%gs' % a for a in elapsed), sum(elapsed))
		info = '\n'.join(('length: %d; lang=%s; est=%s; objfun=%s; marg=%s' % (
				len(senttok), lang, est, objfun, marg), msg, elapsed,
				'10 most probable parse trees:',
				''.join('%d. [%s] %s' % (n + 1, probstr(prob),
						writediscbrackettree(tree, senttok))
						for n, (tree, prob, _) in enumerate(parsetrees))
				+ '\n'))
		CACHE.set(key, (sent, result, nbest, info, link, dep, depsvg),
				timeout=5000)
	else:
		(sent, result, nbest, info, link, dep, depsvg) = resp
	if html:
		return render_template('parsetree.html', sent=sent, result=result,
				nbest=nbest, info=info, link=link, dep=dep,
				depsvg=depsvg, randid=randid())
	else:
		return Response('\n'.join((nbest, info, result)),
				mimetype='text/plain')


@APP.route('/parser/favicon.ico')
def favicon():
	"""Serve the favicon."""
	return send_from_directory(os.path.join(APP.root_path, 'static'),
			'parse.ico', mimetype='image/vnd.microsoft.icon')


@APP.route('/parser/static/script.js')
def javascript():
	"""Serve javascript."""
	return send_from_directory(os.path.join(APP.root_path, 'static'),
			'script.js', mimetype='text/javascript')


@APP.route('/parser/static/style.css')
def stylecss():
	"""Serve style.css."""
	return send_from_directory(os.path.join(APP.root_path, 'static'),
			'style.css', mimetype='text/css')


def loadparsers():
	"""Load grammars if necessary."""
	if not PARSERS:
		for directory in glob.glob('grammars/*/'):
			_, lang = os.path.split(os.path.dirname(directory))
			APP.logger.info('Loading grammar %r', lang)
			params = readparam(os.path.join(directory, 'params.prm'))
			params.resultdir = directory
			readgrammars(directory, params.stages, params.postagging,
					top=getattr(params, 'top', 'ROOT'))
			PARSERS[lang] = Parser(params)
			APP.logger.info('Grammar for %s loaded.', lang)
	assert PARSERS, 'no grammars found!'


def randid():
	"""Return a string with 6 random letters."""
	return ''.join(random.choice(string.ascii_letters)
		for _ in range(6))


# List of contractions adapted from Robert MacIntyre's tokenizer.
CONTRACTIONS2 = re.compile(
		"(?i)(?:%s)\b" % "|".join([
		r"(.)('ll|'re|'ve|n't|'s|'m|'d)",
		r"\b(can)(not)",
		r"\b(D)('ye)",
		r"\b(Gim)(me)",
		r"\b(Gon)(na)",
		r"\b(Got)(ta)",
		r"\b(Lem)(me)",
		r"\b(Mor)('n)",
		r"\b(T)(is)",
		r"\b(T)(was)",
		r"\b(Wan)(na)"]))
CONTRACTIONS3 = re.compile(r"(?i)\b(?:(Whad)(dd)(ya)|(Wha)(t)(cha))\b")


def tokenize(text):
	"""A tokenizer with specific support for splitting English contractions.

	Adapted from nltk.tokenize.TreebankTokenizer."""
	text = CONTRACTIONS2.sub(r'\1 \2', text)
	text = CONTRACTIONS3.sub(r'\1 \2 \3', text)
	# Separate most punctuation
	text = re.sub(r"([^\w\.\'\-\/,&])", r' \1 ', text, flags=re.UNICODE)
	# Separate commas if they're followed by space; e.g., don't separate 2,500
	# Separate single quotes if they're followed by a space.
	text = re.sub(r"([,']\s)", r' \1', text)
	# Separate periods that come before newline or end of string.
	text = re.sub(r'\. *(\n|$)', ' . ', text)
	return tuple(text.split())


def unigramprob(model, sent, smooth=-math.log(1e-20)):
	"""Simple smoothed unigram probability of sentence given grammar.

	:returns: a logprob for the sentence given lexical probabilities in first
		stage of ``model`` of the most likely POS tag for each word;
		or ``smooth`` if the word is not in the lexicon."""
	grammar = model.stages[0].grammar
	if not grammar.logprob:
		return sum(-math.log(max(grammar.getlexprobs(word),
				default=-math.exp(smooth))) for word in sent)
	return sum(min(grammar.getlexprobs(word), default=smooth) for word in sent)


def guesslang(sent):
	"""Heuristic: pick language that contains most words from input."""
	probs = {lang: unigramprob(PARSERS[lang], sent) for lang in PARSERS}
	APP.logger.info('Lang: %r; Sent: %s', probs, ' '.join(sent))
	return min(probs, key=probs.get)


def replacemorph(tree):
	"""Replace POS tags with morphological tags if available."""
	for node in tree.subtrees(
			lambda n: n and not isinstance(n[0], Tree)):
		x = (node.source[treebank.MORPH]
				if hasattr(node, 'source') and node.source else None)
		if x and x != '--':
			treebank.handlemorphology('replace', None, node, node.source)
		node.label = node.label.replace('[]', '')


logging.basicConfig()
for log in (logging.getLogger(), APP.logger):
	log.setLevel(logging.DEBUG)
	log.handlers[0].setFormatter(logging.Formatter(
			fmt='%(asctime)s %(message)s', datefmt='%Y-%m-%d %H:%M:%S'))
loadparsers()


if __name__ == '__main__':
	import sys
	from getopt import gnu_getopt
	opts, _args = gnu_getopt(sys.argv[1:], '', ['port=', 'ip=', 'debug'])
	opts = dict(opts)
	APP.run(debug='--debug' in opts, host=opts.get('--ip', '0.0.0.0'),
			port=int(opts.get('--port', 5000)))
