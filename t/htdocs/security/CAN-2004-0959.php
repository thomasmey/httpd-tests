<?php
 if (array_key_exists('user_file', $_FILES) &&
     is_uploaded_file($_FILES['user_file']['tmp_name'])) {
     print $_FILES['user_file']['name'];
 } else {
     print "FAILED";
 }
?>
