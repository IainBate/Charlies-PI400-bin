#!/usr/bin/python

# processdir.py 0.1 - batch run a hardcoded command line.
# Original verison written by Sitsofe Wheeler.
# This code is public domain - do with it as you wish!

import datetime, os, pipes, string, subprocess, sys
from optparse import OptionParser

# Crude file class
class Fancyfile:
	oldpath = ""
	newpath = ""
	stat = None
	groupkey = ""
	sortkey = ""
	mtime = None

	# Pretty printed version of this class (doesn't print the stat object for
	# the sake of brevity)
	def __repr__(self):
		return "<oldpath=%s, newpath=%s, stat=%s, groupkey=%s>" % (self.oldpath, self.newpath, "<stat object>", self.groupkey)

# Function to only print debugging output
def debugprint(output, verbose):
	if verbose:
		print(output, file=sys.stderr)

# Returns True if a path is only a file, False otherwise
def isonlyfile(path):
	return not(os.path.islink(path)) and os.path.isfile(path)

# Takes a list of Fancyfiles and fills in the newname of each Fancyfile
def createnewnames(directory, files):
	# Group matching prefix files together and set the sortkey
	groupedfiles = {}
	for file in files:
		file.groupkey = datetime.date.fromtimestamp(file.mtime).strftime("%Y%m%d")
		file.sortkey = file.mtime
		if not (file.groupkey in groupedfiles):
			groupedfiles[file.groupkey] = []
		groupedfiles[file.groupkey] += [file]

	# Create new filenames, where files with a common prefix get letters A-Z
	# appended
	for filelist in groupedfiles.values():
		# When there are multiple files with a common prefix...
		if len(filelist) > 1:
			pos = 0
			filelist.sort(key=lambda x: x.sortkey)
		else:
			pos = -1

		for file in filelist:
			if pos > -1:
				# FIXME: We're in trouble if we have more than 26 files in the
				# same group...
				if pos >= 26:
	 				postfix = " A" + string.ascii_uppercase[pos-26]
				else:
					postfix = " " + string.ascii_uppercase[pos]
			else:
				postfix = ""

			# Destination filename is defined on the following line
			newname = datetime.date.fromtimestamp(file.mtime).strftime("Movie %d_%m_%Y" + postfix + ".mp4")
			file.newpath = os.path.join(directory, newname)

			if pos > -1:
				pos += 1

# Check whether the new file already exists
def nameclash(files):
	names = {}
	allpaths = [file.newpath for file in files]
	clash = False
	for file in files:
		if os.path.exists(file.newpath):
			print("Processing '%s' would create file '%s' which already exists. See --help on how to disable this check.\n" % (file.oldpath, file.newpath), file=sys.stderr)
			clash = True
	
	return clash

# Parse command line options
def getopts():
	usage = "usage: %prog [options] SRCDIR"
	parser = OptionParser(usage=usage)
	parser.add_option("-d", "--destination", dest="destdir",
			help="the destination directory for processing", action="store")
	parser.add_option("-e", "--extension", dest="extension",
			help="only process files that match EXTENSION [default: %default,"
			" use \"\" for all files]", action="store", default=".MOV")
	parser.add_option("-f", "--force", dest="force",
			help="overwrite files that already exist", action="store_true")
	parser.add_option("-v", "--verbose", dest="verbose", default=False,
			help="print debugging output", action="store_true", )

	(options, args) = parser.parse_args()
	if len(args) != 1:
		parser.error("Need exactly one input directory.")
	
	options.srcdir = args[0]
	if not options.destdir:
		options.destdir = options.srcdir

	return options

# Run the processing step for each file
def process(files, dest, verbose):
	# The command to be run for every file. %s will be replaced by parameters
	# defined a bit later (in cmdline). String cmd uses """ so it can span
	# multiple lines:
	cmd = """nice -n 20 ffmpeg -y -i %s -threads 4 -map_metadata 0 -map 0:v:0 -c:v libx264 -crf 21 -map 0:a:0 -q:a 1 %s; rm *.log %s"""
	# Example "command" (will moan about non existant new file).
#	cmd = "echo %s %s; cp %s %s"

	# Try to make the directory if it doesn't exist
	if not os.path.exists(dest):
		os.mkdir(dest)
	elif not(os.path.isdir(dest)):
		print("Destination '%s' is not a directory." % (dest), file=sys.stderr)
		return 1

	for file in files:
		# TODO: The quoting that follows is hacky but it's that or doing things
		# "properly" rather than as one big shell command
		quoted_old = pipes.quote(file.oldpath)
		quoted_new = pipes.quote(file.newpath)

		# Here's the bit where %s's in cmd are replaced by strings
		cmdline = cmd % (quoted_old, quoted_new, quoted_old)

		debugprint("+ " + cmdline, verbose)
		subprocess.call(cmdline, shell=True)

		# Fix up created file's timestamps
		if os.path.exists(file.newpath):
			os.utime(file.newpath, (file.stat.st_atime, file.stat.st_mtime))

# Return a list of file paths that end with extension
def getfiles(srcdir, extension, verbose):
	paths = [os.path.join(srcdir, name) for name in
			os.listdir(srcdir)]

	filepaths = filter(os.path.isfile, paths)
	debugprint("Unfiltered file paths: %s" % (filepaths), verbose)
	
	if extension:
		hasext = lambda path: path.endswith(extension)
		filepaths = filter(hasext, filepaths)

	debugprint("Keeping files ending with %s" % (extension), verbose)
	debugprint("Filtered file paths: %s" % (filepaths), verbose)

	return filepaths

def main():
	options = getopts()

	# Get the files in directory that end with a particular extension
	filepaths = getfiles(options.srcdir, options.extension, options.verbose)

	# Create a list of "files" with attributes
	files = []
	for path in filepaths:
		file = Fancyfile()
		file.oldpath = path
		file.stat = os.stat(path)
		file.mtime = file.stat.st_mtime
		files += [file]

	# Fill in the new filename on files
	createnewnames(options.destdir, files)

	if (not options.force) and nameclash(files):
		return 1

	# Process each file
	process(files, options.destdir, options.verbose)

if __name__ == "__main__":
	main()
