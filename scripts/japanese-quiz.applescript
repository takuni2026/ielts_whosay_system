on run
	set requestToken to do shell script "/usr/bin/uuidgen"
	set applicationSupportPath to POSIX path of (path to application support folder from user domain)
	set replyFolder to applicationSupportPath & "com.macielts.practice/automation"
	set replyPath to replyFolder & "/" & requestToken & ".txt"

	do shell script "/bin/mkdir -p " & quoted form of replyFolder
	do shell script "/bin/rm -f " & quoted form of replyPath
	do shell script "/usr/bin/open -g " & quoted form of ("ieltspractice://japanese-quiz?requestID=" & requestToken)

	set timeoutAt to (current date) + 240
	repeat
		set replyExists to do shell script "/bin/test -f " & quoted form of replyPath & " && /bin/echo yes || /bin/echo no"
		if replyExists is "yes" then
			set replyText to do shell script "/bin/cat " & quoted form of replyPath
			set separatorPosition to offset of linefeed in replyText
			if separatorPosition is 0 then
				do shell script "/bin/rm -f " & quoted form of replyPath
				error "アプリから正しい回答データを受け取れませんでした。" number -2700
			end if

			set replyStatus to text 1 thru (separatorPosition - 1) of replyText
			set replyBody to text (separatorPosition + 1) thru -1 of replyText
			do shell script "/bin/rm -f " & quoted form of replyPath
			if replyStatus is "OK" then return replyBody
			error replyBody number -128
		end if

		if (current date) > timeoutAt then
			do shell script "/bin/rm -f " & quoted form of replyPath
			error "回答生成が4分以内に完了しませんでした。アプリの状態を確認してください。" number -1712
		end if
		delay 1
	end repeat
end run
