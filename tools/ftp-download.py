#!/usr/bin/env python3

from ftplib import FTP
import sys, os, stat
import hashlib
import csv
import re
import progressbar
import datetime

# =================================================================================================
#     Settings
# =================================================================================================

# CSV table listing all the FTP server/user combinations that we want to get files from.
# The table needs to have at least the following columns: host,username,password, as well as a column
# that specifies the target directory to which the files from that server/user are downloaded to.
# The name of that column can be set with run_table_target_col
run_table = "runs.csv"
run_table_target_col = "submission_date"

# Log file where all FTP download attempts are logged
ftp_download_log_file = "ftp-download.log"

# File name search pattern (regex) for finding a file with md5 hashes of the files on the server.
md5_file_re = ".*/md5\.txt"

# Summary of all processed files
summary = {}

# =================================================================================================
#     Structures
# =================================================================================================

# Plain data class of information about files we are downloading.
# `status` is supposed to be a single character, which we use as follows:
#  - 'N': file does not exists locally
#  - 'S': file exists and has the correct size and md5 hash, so we can skip it
#  - 'R': file exists, but has a different size or md5 hash than on the server, so we need to replace/re-download it
#  - 'D': new download of non existing file
#  - 'E': some error occurred
class FileInfo:

    # Init function that expects the minimum data that we need to get the file.
    def __init__(self, host, user, remote_path, local_path):
        # Where the file is downloaded from, and remote file information
        self.host = host
        self.user = user
        self.remote_path = remote_path
        self.remote_size = None
        self.remote_md5_hash = None

        # Local file information, and overall status
        self.local_path = local_path
        self.local_size = None
        self.local_md5_hash = None
        self.status = None

# =================================================================================================
#     General Helpers
# =================================================================================================

# We log each FTP download and its properties, to be sure we don't miss anything.
# Expects a FileInfo object.
def write_ftp_download_log(fileinfo):
    with open( ftp_download_log_file, "a") as logfile:
        now = datetime.datetime.now().strftime("%Y-%m-%d\t%H:%M:%S")
        logfile.write(
            now + "\t" + str(fileinfo.host) + "\t" + str(fileinfo.user) + "\t" +
            str(fileinfo.status) + "\t" + str(fileinfo.local_md5_hash) + "\t" + str(fileinfo.local_size) + "\t" +
            str(fileinfo.local_path) + "\n"
        )

# Given a file as produced by the unix `md5sum` command, return a dict from file names to
# their hashes. The file is typically named `md5.txt`, and its expected file format consists
# of rows of the format `<hash>  <filename>`.
def get_md5_hash_dict(md5_file):
    hashdict = {}
    with open(md5_file) as fp:
        for line in fp:
            sl = [item for item in re.split("\s+", line) if item]
            if len(sl) == 0:
                continue
            elif len(sl) > 2:
                raise Exception("md5 file " + md5_file + " has a line with more than 2 columns.")
            assert len(sl) == 2
            if len(sl[0]) != 32:
                raise Exception("md5 file " + md5_file + " has a line with an invalid md5 hash.")

            if sl[1] in hashdict:
                raise Exception("md5 file " + md5_file + " has multiple entries for file " + sl[1])
            else:
                hashdict[sl[1]] = sl[0]
    return hashdict

# Compute the md5 hash of a given local file, efficiently (hopefully?! not all to sure about large
# file handling in python...) by using blocks of data instead of reading the (potentially huge)
# files all at once in to memory.
def get_file_md5(filename, blocksize=65536):
    if not os.path.isfile(filename):
        raise Exception("Cannot compute md5 hash for path \"" + filename + "\"")
    md5_hash = hashlib.md5()
    with open(filename, "rb") as f:
        for chunk in iter(lambda: f.read(blocksize), b""):
            md5_hash.update(chunk)
    return md5_hash.hexdigest()

# Check local file properties against remote: file size and md5 hash have to match.
# Expects to be given a FileInfo object.
# Return True if they match (file is good), or False if either is wrong (file needs to be
# downloaded [again]). Also, fill in the values in the FileInfo while doing so.
def get_and_check_file_properties( fileinfo ):
    if not os.path.exists(fileinfo.local_path):
        raise Exception("Local path \"" + fileinfo.local_path + "\" does not exists.")
    if not os.path.isfile(fileinfo.local_path):
        raise Exception("Local path \"" + fileinfo.local_path + "\" exists, but is not a file.")

    # Get and check file size.
    fileinfo.local_size = os.stat(fileinfo.local_path).st_size
    if fileinfo.local_size != fileinfo.remote_size:
        print(
            "Local file \"" + fileinfo.local_path + "\" exists, but has size", str(fileinfo.local_size),
            "instead of remote file size", str(fileinfo.remote_size) + "."
        )
        return False

    # Compute local file md5 hash.
    if fileinfo.remote_md5_hash:
        fileinfo.local_md5_hash = get_file_md5( fileinfo.local_path )
    else:
        fileinfo.local_md5_hash = None

    # Check that we got the correct md5 hash.
    if fileinfo.local_md5_hash != fileinfo.remote_md5_hash:
        print(
            "Local file \"" + fileinfo.local_path + "\" exists, " +
            "but its md5 hash does not match the remote md5 hash."
        )
        return False

    # If we are here, everything is good.
    assert fileinfo.local_size == fileinfo.remote_size
    assert fileinfo.local_md5_hash == fileinfo.remote_md5_hash
    return True

# =================================================================================================
#     FTP Helpers
# =================================================================================================

# Test whether a name is a file or not - so, probably a directory? FTP is messy...
# But that's the best we can do with the limitations of that protocol.
def ftp_is_file(ftp, name):
    try:
        fs = ftp.size(name)
    except:
        return False
    return fs is not None

# Get all names (files and dirs) in the given or the current working directory.
def ftp_get_list(ftp, dir=None):
    try:
        if dir:
            names = ftp.nlst(dir)
        else:
            names = ftp.nlst()
    except( ftplib.error_perm, resp ):
        if str(resp) == "550 No files found":
            return []
        else:
            raise
    return names

# Get all file names in the current working directory.
def ftp_get_files(ftp, dir=None):
    names = ftp_get_list(ftp, dir)
    return [ n for n in names if ftp_is_file(ftp, n) ]

# Get all directory names in the current working directory. Hopefully.
def ftp_get_dirs(ftp, dir=None):
    names = ftp_get_list(ftp, dir)
    return [ n for n in names if not ftp_is_file(ftp, n) ]

# =================================================================================================
#     FTP Download
# =================================================================================================

# Download a specific file, and fill in the respective FileInfo data.
def ftp_download_file(ftp, fileinfo):
    # Init the (expected) remote file size.
    fileinfo.remote_size = ftp.size(fileinfo.remote_path)
    if fileinfo.remote_size is None:
        raise Exception(
            "Cannot work with a server that does not support to retreive file sizes. " +
            "Feel free however to refactor this script accordingly."
        )

    # Check that we do not overwrite files accidentally, that is, only download again if the file
    # does not match its expectations. If all is good, we can skip the file.
    if os.path.exists(fileinfo.local_path):
        if get_and_check_file_properties(fileinfo):
            print("Local file \"" + fileinfo.local_path + "\" exists and is good. Skipping.")
            fileinfo.status='S'
            return
        else:
            print(
                "Will download the file again."
            )
            fileinfo.status='R'

    # Make the target dir if necessary.
    if not os.path.exists(os.path.dirname( fileinfo.local_path )):
        os.mkdir(os.path.dirname( fileinfo.local_path ))

    # Report progress while downloading. We have gigabytes of data, so that is important.
    print("\nDownloading \"" + fileinfo.remote_path + "\"...", flush=True)
    pbar = progressbar.ProgressBar( max_value = (
        fileinfo.remote_size if fileinfo.remote_size is not None else progressbar.UnknownLength
    ))
    pbar.start()

    # Open the file locally, and define a callback that writes to that file while reporting progress.
    filehandle = open(fileinfo.local_path, 'wb')
    def file_write_callback(data):
        filehandle.write(data)
        nonlocal pbar
        pbar += len(data)

    # Go go gadget!
    try:
        ftp.retrbinary("RETR " + fileinfo.remote_path, file_write_callback)
    except ex:
        print("Error downloading file:", str(ex))
        fileinfo.status='E'
    pbar.finish()
    filehandle.close()

    # Check that we got the correct size, and the correct md5 hash,
    # and if so, make it read-only, and return.
    if get_and_check_file_properties(fileinfo):
        print("Done. File passed file size and md5 hash checks.")
        if fileinfo.status != 'R':
            fileinfo.status='D'
        os.chmod( fileinfo.local_path, stat.S_IREAD | stat.S_IRGRP | stat.S_IROTH )
    else:
        print("Error downloading file!")
        fileinfo.status='E'

# Download all files from an FTP server into a target directory.
def ftp_download_all(host, user, passwd, target_dir):
    # Check target.
    if os.path.exists(target_dir):
        if not os.path.isdir(target_dir):
            raise Exception("Local path", target_dir, "exists, but is not a directory.")
    else:
        os.mkdir(target_dir)

    # Connect to FTP server.
    ftp = FTP( host )
    ftp.login( user=user, passwd=passwd )

    # We work through all directories on the server, and store them in a queue
    # that we process dir by dir, pushing new (sub)dirs as we discover them.
    # Initialize with the current dir (after login) of the server.
    queue = ftp_get_dirs(ftp)
    while len(queue) > 0:
        dir = queue.pop(0)
        print("-----------------------------------------------------------------------------------")
        print("Processing", dir)

        # Add all subdirs of the current one to the queue.
        for f in ftp_get_dirs( ftp, dir ):
            queue.append( f )

        # Get list of all files in the dir.
        files = ftp_get_files( ftp, dir )
        # print("Files:", files)

        # If there is an md5 hash file in that directory for the files in there, get that first,
        # so that we can check hashes for each downloaded file.
        md5_hashes = {}
        if md5_file_re is not None:
            # See if there is a file in the list that fits our regular expression.
            md5_regex = re.compile(md5_file_re)
            md5_match_list = list(filter(md5_regex.match, files))
            if len(md5_match_list) > 1:
                raise Exception("Multiple md5 hash files found. Refine your regex to find the file.")
            elif len(md5_match_list) == 1:
                # Get the md5 txt file, as produced by the unix `md5sum` command.
                # First, prepare is properties.
                md5_remote_file = md5_match_list[0]
                print("Using md5 file", md5_remote_file)
                md5_local_file = os.path.join( target_dir, md5_remote_file )
                md5_fileinfo = FileInfo( host, user, md5_remote_file, md5_local_file )

                # Now, download it, and remove it from the file list, so that we don't download
                # it again. Then, extract a dict of all hashes for the files.
                ftp_download_file( ftp, md5_fileinfo )
                write_ftp_download_log( md5_fileinfo )
                files.remove(md5_remote_file)
                md5_hashes = get_md5_hash_dict(md5_local_file)

        # Download them all!
        print()
        for f in files:
            # Initialize a FileInfo where we capture all info as we process that file.
            fileinfo = FileInfo( host, user, f, os.path.join( target_dir, f ))

            # See if there is an md5 hash that we can use to check the file contents.
            fbn = os.path.basename(fileinfo.remote_path)
            if fbn in md5_hashes:
                fileinfo.remote_md5_hash = md5_hashes[fbn]
            else:
                fileinfo.remote_md5_hash = None

            # Download the file, do all checks, and write a log line about it.
            ftp_download_file( ftp, fileinfo )
            write_ftp_download_log(fileinfo)

            # Summary of all downloads. Cumbersome, because Python...
            if fileinfo.status in summary:
                summary[fileinfo.status] += 1
            else:
                summary[fileinfo.status] = 1
        print()

    # We are polite, and close the connection respectfully. Bye, host.
    ftp.quit()

# =================================================================================================
#     Table of Sequencing Runs
# =================================================================================================

if __name__ == "__main__":
    with open( run_table ) as csvfile:
        runreader = csv.DictReader(csvfile, delimiter=',', quotechar='"')
        for row in runreader:
            print("===================================================================================")
            print("Connecting to " + row["host"] + " as " + row["username"])
            print()

            ftp_download_all( row["host"], row["username"], row["password"], row[run_table_target_col] )

    print("Summary:")
    for key, val in summary.items():
        print(key + ": " + str(val))
