// RGB standard library
// Written in 2019-2022 by
//     Dr. Maxim Orlovsky <orlovsky@lnp-bp.org>
//
// To the extent possible under law, the author(s) have dedicated all
// copyright and related and neighboring rights to this software to
// the public domain worldwide. This software is distributed without
// any warranty.
//
// You should have received a copy of the MIT License
// along with this software.
// If not, see <https://opensource.org/licenses/MIT>.

use bp::dbc::{Anchor, AnchorId};
use commit_verify::lnpbp4::MerkleBlock;
use rgb::NodeId;

use crate::error::ServiceErrorDomain;

pub trait Index {
    type Error: ::std::error::Error + Into<ServiceErrorDomain>;

    fn anchor_id_by_transition_id(&self, tsid: NodeId) -> Result<AnchorId, Self::Error>;

    fn index_anchor(&mut self, anchor: &Anchor<MerkleBlock>) -> Result<bool, Self::Error>;
}
