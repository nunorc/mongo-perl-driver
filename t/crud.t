#
#  Copyright 2015 MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

use strict;
use warnings;
use Test::More 0.96;
use Test::Fatal;
use Test::Warn;
use Test::Deep qw/!blessed/;

use utf8;
use Tie::IxHash;

use MongoDB;
use MongoDB::Error;

use lib "t/lib";
use MongoDBTest qw/build_client get_test_db server_version server_type get_capped/;

my $conn           = build_client();
my $testdb         = get_test_db($conn);
my $server_version = server_version($conn);
my $server_type    = server_type($conn);
my $coll           = $testdb->get_collection('test_collection');

my $res;

subtest "insert_one" => sub {

    # insert doc with _id
    $coll->drop;
    $res = $coll->insert_one( { _id => "foo", value => "bar" } );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => "foo", value => "bar" } ),
        "insert with _id: doc inserted"
    );
    ok( $res->acknowledged, "result acknowledged" );
    isa_ok( $res, "MongoDB::InsertOneResult", "result" );
    is( $res->inserted_id, "foo", "res->inserted_id" );

    # insert doc without _id
    $coll->drop;
    $res = $coll->insert_one( { value => "bar" } );
    my @got = $coll->find( {} )->all;
    cmp_deeply(
        \@got,
        bag( { _id => ignore(), value => "bar" } ),
        "insert without _id: hash doc inserted"
    );
    ok( $res->acknowledged, "result acknowledged" );
    is( $got[0]{_id}, $res->inserted_id, "doc has expected inserted _id" );

    # insert arrayref
    $coll->drop;
    $res = $coll->insert_one( [ value => "bar" ] );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), value => "bar" } ),
        "insert without _id: array doc inserted"
    );

    # insert Tie::Ixhash
    $coll->drop;
    $res = $coll->insert_one( Tie::IxHash->new( value => "bar" ) );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), value => "bar" } ),
        "insert without _id: Tie::IxHash doc inserted"
    );

};

subtest "insert_many" => sub {

    # insert docs with mixed _id and not and mixed types
    $coll->drop;
    my $doc = { value => "baz" };
    $res =
      $coll->insert_many( [ [ _id => "foo", value => "bar" ], $doc, ] );
    my @got = $coll->find( {} )->all;
    cmp_deeply(
        \@got,
        bag( { _id => "foo", value => "bar" }, { _id => ignore(), value => "baz" }, ),
        "insert many: docs inserted"
    );
    ok( $res->acknowledged, "result acknowledged" );
    isa_ok( $res, "MongoDB::InsertManyResult", "result" );
    cmp_deeply(
        $res->inserted,
        [ { index => 0, _id => 'foo' }, { index => 1, _id => $doc->{_id} } ],
        "inserted contains correct hashrefs"
    );
    cmp_deeply(
        $res->inserted_ids,
        {
            0 => "foo",
            1 => $doc->{_id}
        },
        "inserted_ids contains correct keys/values"
    );

    # ordered insert should halt on error
    $coll->drop;
    my $err = exception {
        $coll->insert_many( [ { _id => 0 }, { _id => 1 }, { _id => 2 }, { _id => 1 }, ] )
    };
    ok( $err, "ordered insert got an error" );
    isa_ok( $err, 'MongoDB::DuplicateKeyError', 'caught error' )
      or diag explain $err;
    $res = $err->result;
    is( $res->inserted_count, 3, "only first three inserted" );

    # unordered insert should not halt on error
    $coll->drop;
    $err = exception {
        $coll->insert_many( [ { _id => 0 }, { _id => 1 }, { _id => 1 }, { _id => 2 }, ], { ordered => 0 } )
    };
    ok( $err, "unordered insert got an error" );
    isa_ok( $err, 'MongoDB::DuplicateKeyError', 'caught error' )
      or diag explain $err;
    $res = $err->result;
    is( $res->inserted_count, 3, "all valid docs inserted" );

};

subtest "delete_one" => sub {
    $coll->drop;
    $coll->insert_many( [ map { { _id => $_, x => "foo" } } 1 .. 3 ] );
    is( $coll->count( { x => 'foo' } ), 3, "inserted three docs" );
    $res = $coll->delete_one( { x => 'foo' } );
    ok( $res->acknowledged, "result acknowledged" );
    isa_ok( $res, "MongoDB::DeleteResult", "result" );
    is( $res->deleted_count, 1, "delete one document" );
    is( $coll->count( { x => 'foo' } ), 2, "two documents left" );
    $res = $coll->delete_one( { x => 'bar' } );
    is( $res->deleted_count, 0, "delete non existent document does nothing" );
    is( $coll->count( { x => 'foo' } ), 2, "two documents left" );

    # test errors -- deletion invalid on capped collection
    my $cap = get_capped($testdb);
    $cap->insert_many( [ map { { _id => $_ } } 1..10 ] );
    my $err = exception { $cap->delete_one( { _id => 4 } ) };
    ok( $err, "deleting from capped collection throws error" );
    isa_ok( $err, 'MongoDB::WriteError' );
    like( $err->result->last_errmsg, qr/capped/, "error had string 'capped'" );
};

subtest "delete_many" => sub {
    $coll->drop;
    $coll->insert_many( [ map { { _id => $_, x => $_ } } 1 .. 3 ] );
    is( $coll->count( {} ), 3, "inserted three docs" );
    $res = $coll->delete_many( { x => { '$gt', 1 } } );
    ok( $res->acknowledged, "result acknowledged" );
    isa_ok( $res, "MongoDB::DeleteResult", "result" );
    is( $res->deleted_count, 2, "deleted two documents" );
    is( $coll->count( {} ), 1, "one documents left" );
    $res = $coll->delete_many( { y => 'bar' } );
    is( $res->deleted_count, 0, "delete non existent document does nothing" );
    is( $coll->count( {} ), 1, "one documents left" );

    # test errors -- deletion invalid on capped collection
    my $cap = get_capped($testdb);
    $cap->insert_many( [ map { { _id => $_ } } 1..10 ] );
    my $err = exception { $cap->delete_many( {} ) };
    ok( $err, "deleting from capped collection throws error" );
    isa_ok( $err, 'MongoDB::WriteError' );
    like( $err->result->last_errmsg, qr/capped/, "error had string 'capped'" );
};

subtest "replace_one" => sub {
    $coll->drop;

    # replace missing doc without upsert
    $res = $coll->replace_one( { x => 1 }, { x => 2 } );
    ok( $res->acknowledged, "result acknowledged" );
    isa_ok( $res, "MongoDB::UpdateResult", "result" );
    is( $res->matched_count, 0, "matched count is zero" );
    is( $coll->count( {} ), 0, "collection still empty" );

    # replace missing with upsert
    $res = $coll->replace_one( { x => 1 }, { x => 2 }, { upsert => 1 } );
    is( $res->matched_count, 0, "matched count is zero" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 0 : undef ),
        "modified count correct based on server version"
    );
    isa_ok( $res->upserted_id, "MongoDB::OID", "got upserted id" );
    is( $coll->count( {} ), 1, "one doc in database" );
    my $got = $coll->find_one( { _id => $res->upserted_id } );
    is( $got->{x}, 2, "document contents correct" );

    # replace existing with upsert -- add duplicate to confirm only one
    $coll->insert( { x => 2 } );
    $res = $coll->replace_one( { x => 2 }, { x => 3 }, { upsert => 1 } );
    is( $coll->count( {} ), 2, "replace existing with upsert" );
    is( $res->matched_count, 1, "matched_count 1" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 1 : undef ),
        "modified count correct based on server version"
    );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), x => 2 }, { _id => ignore, x => 3 } ),
        "collection docs correct"
    );

    # replace existing without upsert
    $res = $coll->replace_one( { x => 3 }, { x => 4 } );
    is( $coll->count( {} ), 2, "replace existing with upsert" );
    is( $res->matched_count, 1, "matched_count 1" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 1 : undef ),
        "modified count correct based on server version"
    );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), x => 2 }, { _id => ignore, x => 4 } ),
        "collection docs correct"
    );
};

subtest "update_one" => sub {
    $coll->drop;

    # update missing doc without upsert
    $res = $coll->update_one( { x => 1 }, { '$set' => { x => 2 } } );
    ok( $res->acknowledged, "result acknowledged" );
    isa_ok( $res, "MongoDB::UpdateResult", "result" );
    is( $res->matched_count, 0, "matched count is zero" );
    is( $coll->count( {} ), 0, "collection still empty" );

    # update missing with upsert
    $res = $coll->update_one( { x => 1 }, { '$set' => { x => 2 } }, { upsert => 1 } );
    is( $res->matched_count, 0, "matched count is zero" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 0 : undef ),
        "modified count correct based on server version"
    );
    isa_ok( $res->upserted_id, "MongoDB::OID", "got upserted id" );
    is( $coll->count( {} ), 1, "one doc in database" );
    my $got = $coll->find_one( { _id => $res->upserted_id } );
    is( $got->{x}, 2, "document contents correct" );

    # update existing with upsert -- add duplicate to confirm only one
    $coll->insert( { x => 2 } );
    $res = $coll->update_one( { x => 2 }, { '$set' => { x => 3 } }, { upsert => 1 } );
    is( $coll->count( {} ), 2, "update existing with upsert" );
    is( $res->matched_count, 1, "matched_count 1" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 1 : undef ),
        "modified count correct based on server version"
    );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), x => 2 }, { _id => ignore, x => 3 } ),
        "collection docs correct"
    );

    # update existing without upsert
    $res = $coll->update_one( { x => 3 }, { '$set' => { x => 4 } } );
    is( $coll->count( {} ), 2, "update existing with upsert" );
    is( $res->matched_count, 1, "matched_count 1" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 1 : undef ),
        "modified count correct based on server version"
    );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), x => 2 }, { _id => ignore, x => 4 } ),
        "collection docs correct"
    );
};

subtest "update_many" => sub {
    $coll->drop;

    # update missing doc without upsert
    $res = $coll->update_many( { x => 1 }, { '$set' => { x => 2 } } );
    ok( $res->acknowledged, "result acknowledged" );
    isa_ok( $res, "MongoDB::UpdateResult", "result" );
    is( $res->matched_count, 0, "matched count is zero" );
    is( $coll->count( {} ), 0, "collection still empty" );

    # update missing with upsert
    $res = $coll->update_many( { x => 1 }, { '$set' => { x => 2 } }, { upsert => 1 } );
    is( $res->matched_count, 0, "matched count is zero" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 0 : undef ),
        "modified count correct based on server version"
    );
    isa_ok( $res->upserted_id, "MongoDB::OID", "got upserted id" );
    is( $coll->count( {} ), 1, "one doc in database" );
    my $got = $coll->find_one( { _id => $res->upserted_id } );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), x => 2 } ),
        "collection docs correct"
    );

    # update existing with upsert -- add duplicate to confirm multiple
    $coll->insert( { x => 2 } );
    $res = $coll->update_many( { x => 2 }, { '$set' => { x => 3 } }, { upsert => 1 } );
    is( $coll->count( {} ), 2, "update existing with upsert" );
    is( $res->matched_count, 2, "matched_count 2" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 2 : undef ),
        "modified count correct based on server version"
    );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), x => 3 }, { _id => ignore, x => 3 } ),
        "collection docs correct"
    );

    # update existing without upsert
    $res = $coll->update_many( { x => 3 }, { '$set' => { x => 4 } } );
    is( $coll->count( {} ), 2, "update existing with upsert" );
    is( $res->matched_count, 2, "matched_count 1" );
    is(
        $res->modified_count,
        ( $server_version >= v2.6.0 ? 2 : undef ),
        "modified count correct based on server version"
    );
    cmp_deeply(
        [ $coll->find( {} )->all ],
        bag( { _id => ignore(), x => 4 }, { _id => ignore, x => 4 } ),
        "collection docs correct"
    );
};

subtest 'bulk_write' => sub {
    $coll->drop;

    # test mixed-form write models, array/hash refs or pairs
    $res = $coll->bulk_write(
        [
            [ insert_one  => [ { x => 1 } ] ],
            { insert_many => [ { x => 2 }, { x => 3 } ] },
            replace_one => [ { x => 1 }, { x      => 4 } ],
            update_one  => [ { x => 7 }, { '$set' => { x => 5 } }, { upsert => 1 } ],
            [ insert_one  => [ { x => 6 } ] ],
            { insert_many => [ { x => 7 }, { x => 8 } ] },
            delete_one  => [ { x => 4 } ],
            delete_many => [ { x => { '$lt' => 3 } } ],
            update_many => [ { x => { '$gt' => 5 } }, { '$inc' => { x => 1 } } ],
        ],
    );

    ok( $res->acknowledged, "result acknowledged" );
    isa_ok( $res, "MongoDB::BulkWriteResult", "result" );
    is( $res->op_count, 11, "op count correct" );

    my @got = $coll->find( {} )->all;
    cmp_deeply(
        \@got,
        bag( map { { _id => ignore, x => $_ } } 3, 5, 7, 8, 9 ),
        "collection docs correct",
    ) or diag explain \@got;

    # test ordered error
    # ordered insert should not halt on error
    $coll->drop;
    my $err = exception {
        $coll->bulk_write(
            [
                insert_one => [ { _id => 1 } ],
                insert_one => [ { _id => 2 } ],
                insert_one => [ { _id => 1 } ],
            ],
            { ordered => 1, },
        );
    };
    ok( $err, "ordered bulk got an error" );
    isa_ok( $err, 'MongoDB::DuplicateKeyError', 'caught error' )
      or diag explain $err;
    $res = $err->result;
    is( $res->inserted_count, 2, "only first two inserted" );

    # test unordered error
    # unordered insert should halt on error
    $coll->drop;
    $err = exception {
        $coll->bulk_write(
            [
                insert_one => [ { _id => 1 } ],
                insert_one => [ { _id => 2 } ],
                insert_one => [ { _id => 1 } ],
                insert_one => [ { _id => 3 } ],
            ],
            { ordered => 0, },
        );
    };
    ok( $err, "unordered bulk got an error" );
    isa_ok( $err, 'MongoDB::DuplicateKeyError', 'caught error' )
      or diag explain $err;
    $res = $err->result;
    is( $res->inserted_count, 3, "three valid docs inserted" );

};

subtest "find_one_and_delete" => sub {
    $coll->drop;
    $coll->insert_one( { x => 1, y => 'a' } );
    $coll->insert_one( { x => 1, y => 'b' } );
    is( $coll->count( {} ), 2, "inserted 2 docs" );

    my $doc;

    # find non-existent doc
    $doc = $coll->find_one_and_delete( { x => 2 } );
    is( $doc, undef, "find_one_and_delete on nonexistent doc returns undef" );
    is( $coll->count( {} ), 2, "still 2 docs" );

    # find/remove existing doc (testing sort and projection, too)
    $doc = $coll->find_one_and_delete( { x => 1 },
        { sort => [ y => 1 ], projection => { y => 1 } } );
    cmp_deeply( $doc, { _id => ignore(), y => 'a' }, "expected doc returned" );
    is( $coll->count( {} ), 1, "only 1 doc left" );

    # XXX how to test max_time_ms?
};

subtest "find_one_and_replace" => sub {
    $coll->drop;
    $coll->insert_one( { x => 1, y => 'a' } );
    $coll->insert_one( { x => 1, y => 'b' } );
    is( $coll->count( {} ), 2, "inserted 2 docs" );

    my $doc;

    # find and replace non-existent doc, without upsert
    $doc = $coll->find_one_and_replace( { x => 2 }, { x => 3, y => 'c' } );
    is( $doc, undef, "find_one_and_replace on nonexistent doc returns undef" );
    is( $coll->count( {} ), 2, "still 2 docs" );
    is( $coll->count( { x => 3 } ), 0, "no docs matching replacment" );

    # find and replace non-existent doc, with upsert
    $doc = $coll->find_one_and_replace( { x => 2 }, { x => 3, y => 'c' }, { upsert => 1 } );
    is( $doc, undef, "find_one_and_replace upsert on nonexistent doc returns undef" );
    is( $coll->count( {} ), 3, "doc has been upserted" );
    is( $coll->count( { x => 3 } ), 1, "1 doc matching replacment" );

    # find and replace existing doc, with upsert
    $doc = $coll->find_one_and_replace( { x => 3 }, { x => 4, y => 'c' }, { upsert => 1 });
    cmp_deeply(
        $doc,
        { _id => ignore(), x => 3, y => 'c' },
        "find_one_and_replace on existing doc returned old doc",
    );
    is( $coll->count( {} ), 3, "no new doc added" );
    is( $coll->count( { x => 4 } ), 1, "1 doc matching replacment" );

    # find and replace existing doc, with after doc
    $doc = $coll->find_one_and_replace( { x => 4 }, { x => 5, y => 'c' }, { returnDocument => 'after' });
    cmp_deeply(
        $doc,
        { _id => ignore(), x => 5, y => 'c' },
        "find_one_and_replace on existing doc returned new doc",
    );
    is( $coll->count( {} ), 3, "no new doc added" );
    is( $coll->count( { x => 5 } ), 1, "1 doc matching replacment" );

    # test project and sort
    $doc = $coll->find_one_and_replace( { x => 1 }, { x => 2, y => 'z' }, { sort => [ y => -1 ], projection => { y => 1 } } );
    cmp_deeply(
        $doc,
        { _id => ignore(), y => 'b' },
        "find_one_and_replace on existing doc returned new doc",
    );
    is( $coll->count( { x => 2 } ), 1, "1 doc matching replacment" );
    is( $coll->count( { x => 1, y => 'a' } ), 1, "correct doc untouched" );
};

done_testing;
